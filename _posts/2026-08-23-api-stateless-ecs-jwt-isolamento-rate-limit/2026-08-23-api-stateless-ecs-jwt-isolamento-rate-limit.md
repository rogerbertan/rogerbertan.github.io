---
title: "API stateless no ECS: JWT, isolamento de dados e rate limiting"
description: "Como rodar duas tasks atrás de um load balancer determinou o desenho da autenticação, do isolamento por usuário e do limite de tentativas de login"
date: 2026-08-23 10:00:00 -0300
categories: [Backend, Arquitetura]
tags: [java, spring-boot, jwt, spring-security, aws, ecs, seguranca]
---

E aí, pessoal!

No [post anterior](/posts/infra-producao-projeto-pessoal-aws-terraform/) falei da infraestrutura do [Budget Planner](https://github.com/rogerbertan/budget-planner): pipeline autenticando via OIDC, o paradoxo de bootstrap do Terraform e a conta de US$100 por mês.

Agora o outro lado. Três decisões da aplicação que parecem escolhas de framework, mas na verdade foram determinadas pela forma como a infra está desenhada. A mais interessante é a última, porque é a que não funciona direito e eu decidi manter assim.

---

## Stateless porque a infra é stateless

A API valida um JWT a cada requisição, sem sessão guardada em lugar nenhum. Isso não foi preferência, foi consequência desta linha:

```hcl
resource "aws_ecs_service" "budgetplanner_service" {
  desired_count = 2
  launch_type   = "FARGATE"

  network_configuration {
    subnets         = [for subnet in aws_subnet.private : subnet.id]
    security_groups = [aws_security_group.ecs.id]
  }
}
```
{: file='infra/ecs.tf' }

Duas tasks, em subnets diferentes, atrás de um load balancer que distribui as requisições. Um usuário que faz login pode cair na task A e, na requisição seguinte, na task B.

Com sessão em memória isso significa que a segunda requisição não encontra a sessão e o usuário é deslogado. As saídas seriam sticky session, que amarra o usuário a uma instância e quebra quando a task morre, ou um store compartilhado, mais um componente para manter e pagar.

Token assinado dispensa os dois. Qualquer task valida qualquer token, porque a validação depende só da assinatura, não de estado local.

Na configuração isso é explícito:

```java
@Bean
public SecurityFilterChain securityFilterChain(HttpSecurity http) {
    return http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(authorize -> authorize
                    .requestMatchers(HttpMethod.POST, "/api/v1/auth/**").permitAll()
                    .requestMatchers(HttpMethod.GET, "/api/v1/health").permitAll()
                    .anyRequest().authenticated())
            .addFilterBefore(loginRateLimitFilter, UsernamePasswordAuthenticationFilter.class)
            .addFilterBefore(securityFilter, UsernamePasswordAuthenticationFilter.class)
            .build();
}
```
{: file='src/main/java/com/bertan/budgetplanner/config/SecurityConfig.java' }

`SessionCreationPolicy.STATELESS` diz ao Spring para não criar nem consultar `HttpSession` em momento algum. Os dois `addFilterBefore` posicionam os filtros próprios antes de onde o Spring cuidaria de autenticação por formulário.

O filtro roda antes de qualquer controller e, quando o token é válido, coloca o usuário no contexto de segurança:

```java
@Override
protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain) throws ServletException, IOException {
    String authorizationHeader = request.getHeader("Authorization");
    if (Strings.isNotBlank(authorizationHeader) && authorizationHeader.startsWith("Bearer ")) {
        String token = authorizationHeader.substring("Bearer ".length());
        Optional<JWTUserData> optUser = tokenConfig.validateToken(token);

        if (optUser.isPresent()) {
            JWTUserData userData = optUser.get();
            List<SimpleGrantedAuthority> authorities = List.of(
                    new SimpleGrantedAuthority("ROLE_" + userData.role().name()));
            UsernamePasswordAuthenticationToken authenticationToken = new UsernamePasswordAuthenticationToken(
                    userData, null, authorities);
            SecurityContextHolder.getContext().setAuthentication(authenticationToken);
        }
    }
    filterChain.doFilter(request, response);
}
```
{: file='src/main/java/com/bertan/budgetplanner/config/SecurityFilter.java' }

O `JWTUserData` é um record com `userId`, `email` e `role`. É esse objeto que os controllers recebem depois, e ele é a razão da próxima seção funcionar.

> O trade-off do stateless: token assinado não é revogável antes de expirar. Logout descarta o token no cliente, mas se alguém o interceptou, ele vale até o `expiresAt`. Quem precisa de revogação imediata acaba precisando de uma blocklist, e aí volta a ter estado compartilhado.
{: .prompt-warning }

---

## Isolamento na query, não depois

Filtrar por usuário depois de trazer tudo do banco é um erro que funciona em desenvolvimento e vaza em produção. Com cem linhas ninguém percebe. Com um milhão, o banco trabalha o dobro e basta um `if` esquecido num caminho novo para os dados de outra pessoa aparecerem na resposta.

Cada agregação existe em duas versões, e a diferença é uma linha de JPQL:

```java
Page<Transaction> findAllByUserId(Long userId, Pageable pageable);

Optional<Transaction> findByIdAndUserId(Long id, Long userId);

@Query("SELECT COALESCE(SUM(t.amount), 0) FROM Transaction t " +
        "WHERE t.type = :type")
BigDecimal sumAmountByType(@Param("type") Type type);

@Query("SELECT COALESCE(SUM(t.amount), 0) FROM Transaction t " +
        "WHERE t.type = :type " +
        "AND t.user.id = :userId")
BigDecimal sumAmountByTypeAndUserId(@Param("type") Type type, @Param("userId") Long userId);
```
{: file='src/main/java/com/bertan/budgetplanner/repository/TransactionRepository.java' }

O `AND t.user.id = :userId` vai junto no `WHERE`, então o banco nunca lê as linhas dos outros. Em agregações isso importa mais ainda: um `SUM` sem o filtro somaria transações de todo mundo, e nenhum filtro em memória depois desfaria o resultado.

A escolha entre as duas versões fica no service, e é o único lugar onde ela existe:

```java
private Transaction findOwnedOrAnyIfAdmin(Long id, JWTUserData principal) {

    if (principal.role() == Role.ADMIN) {
        return transactionRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Transaction", id.toString()));
    }

    return transactionRepository.findByIdAndUserId(id, principal.userId())
            .orElseThrow(() -> new ResourceNotFoundException("Transaction", id.toString()));
}
```
{: file='src/main/java/com/bertan/budgetplanner/service/TransactionService.java' }

O usuário comum busca por `id` **e** `userId` ao mesmo tempo. Se o id existir mas pertencer a outra pessoa, o retorno é `Optional.empty()`, que vira o mesmo 404 de um id inexistente. Isso não é só conveniência: responder 403 confirmaria ao atacante que aquele registro existe.

O detalhe que fecha a cadeia é de onde vem o `userId`. Ele nunca chega pelo request:

```java
@GetMapping("/{id}")
public ResponseEntity<TransactionResponse> getTransactionById(
        @PathVariable Long id,
        @AuthenticationPrincipal JWTUserData principal) {

    return ResponseEntity.ok(transactionService.getTransactionById(id, principal));
}
```
{: file='src/main/java/com/bertan/budgetplanner/controller/TransactionController.java' }

O `@AuthenticationPrincipal` pega o objeto que o filtro colocou no contexto a partir do token assinado. Se o `userId` viesse de um query param, bastaria trocar o número para ler dados alheios. Vindo do token, alterá-lo invalida a assinatura.

Como toda consulta passa a filtrar por essa coluna, ela precisa de índice:

```sql
ALTER TABLE transactions
    ADD COLUMN user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE;

CREATE INDEX idx_transactions_user_id ON transactions(user_id);
```
{: file='src/main/resources/db/migration/V5__Add_user_id_to_transactions_table.sql' }
{: .nolineno }

---

## Rate limiting e onde ele quebra

O login tem limite de cinco tentativas por minuto por IP, com Bucket4j, e devolve 429 quando estoura:

```java
private Bucket createLoginBucket() {
    return Bucket.builder()
            .addLimit(limit -> limit
                    .capacity(5)
                    .refillGreedy(5, Duration.ofMinutes(1)))
            .build();
}

private final Map<String, Bucket> buckets = new ConcurrentHashMap<>();

private String resolveUserIp(HttpServletRequest request) {
    String forwardedFor = request.getHeader("X-Forwarded-For");
    if (forwardedFor != null && !forwardedFor.isBlank()) {
        return forwardedFor.split(",")[0].trim();
    } else {
        return request.getRemoteAddr();
    }
}
```
{: file='src/main/java/com/bertan/budgetplanner/config/LoginRateLimitFilter.java' }

O `X-Forwarded-For` aparece porque a aplicação está atrás do ALB. Sem ele, `getRemoteAddr()` devolveria o IP do load balancer e todos os usuários do mundo dividiriam o mesmo bucket.

Agora a parte que interessa mais que a implementação. Repare no `ConcurrentHashMap`: o estado vive na memória da JVM.

> Como o ECS roda duas tasks, o limite vale **por instância**, não globalmente. Um atacante cujas requisições caiam alternadamente nas duas tem, na prática, dez tentativas por minuto em vez de cinco. E cada deploy zera os contadores, porque as tasks são substituídas.
{: .prompt-warning }

Resolver de verdade exigiria mover os buckets para um backend compartilhado, tipo Redis no ElastiCache, para que as instâncias contassem no mesmo lugar. O Bucket4j suporta isso, então a mudança seria mais de infraestrutura que de código.

Para o tamanho deste projeto o trade-off compensa: cinco por instância ainda corta um brute-force ingênuo, e manter um Redis não se justifica. Mas essa é uma decisão de escala, não uma solução. Em produção com dados reais, o caminho seria sair da memória da JVM.

A escolha do IP como chave também tem custo: não impede que um mesmo IP tente uma senha contra vários usuários diferentes, já que o limite não é por conta. Cobre o caso mais comum, mas não é proteção por credencial.

---

## Conclusão

As três decisões vieram do mesmo lugar. Duas tasks atrás de um load balancer tornam qualquer estado local uma armadilha: sessão em memória desloga o usuário, bucket em memória multiplica o limite pelo número de instâncias. O que muda é que na autenticação eu eliminei o estado, e no rate limiting eu o mantive sabendo do custo.

Essa é a diferença que vale registrar. Um limite documentado é uma decisão; um limite não percebido é uma garantia falsa que alguém vai confiar mais tarde.

Se você roda mais de uma instância de qualquer coisa, vale procurar onde ainda existe estado em memória e escrever ao lado o que acontece quando a requisição cai na outra.

---

## Referências Técnicas

* [Repositório do Budget Planner](https://github.com/rogerbertan/budget-planner) - Código completo da API, com as decisões documentadas no README.
* [Infra de produção em projeto pessoal](/posts/infra-producao-projeto-pessoal-aws-terraform/) - O post anterior desta série, sobre OIDC, Terraform e custo na AWS.
* [Spring Security: Stateless Authentication](https://docs.spring.io/spring-security/reference/servlet/authentication/session-management.html) - Referência oficial sobre políticas de criação de sessão.
* [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) - Origem da referência de cinco tentativas por minuto no login.
* [Bucket4j: Distributed facilities](https://bucket4j.com/) - Documentação do token bucket usado, incluindo os backends distribuídos.
* [JSON Web Token Best Current Practices (RFC 8725)](https://datatracker.ietf.org/doc/html/rfc8725) - Boas práticas de uso de JWT, incluindo os limites da revogação.

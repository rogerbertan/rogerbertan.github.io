---
title: "Infra de produção em projeto pessoal: OIDC, Terraform e o custo real da AWS"
description: "Pipeline sem Access Key salva em secret, o paradoxo de bootstrap do Terraform e a conta de US$100 que chega mesmo com zero tráfego"
date: 2026-08-22 10:00:00 -0300
categories: [Backend, Arquitetura]
tags: [aws, terraform, oidc, ecs, ci-cd, seguranca, devops]
image:
  path: /assets/img/posts/2026-08-22-infra-producao-projeto-pessoal-aws-terraform/infra-aws-terraform.webp
  alt: Infraestrutura de produção na AWS provisionada com Terraform
---

E aí, pessoal!

Passei as últimas semanas mexendo num projeto pessoal, mas tratando a infra dele como se fosse produção de verdade. É uma API de finanças pessoais, o [Budget Planner](https://github.com/rogerbertan/budget-planner), e a parte interessante não foi a API. Foi tudo em volta: como ela sobe, como se protege e o que acontece quando quebra.

Este post cobre a infraestrutura: autenticação do pipeline sem segredo fixo, o problema de ovo e galinha do Terraform e a conta no fim do mês. As decisões do lado da aplicação estão no [post seguinte](/posts/api-stateless-ecs-jwt-isolamento-rate-limit/).

---

## O desenho

![Diagrama da infraestrutura na AWS](/assets/img/posts/2026-08-22-infra-producao-projeto-pessoal-aws-terraform/infra-aws-diagram.webp){: w="1600" h="1350" }
_Duas tasks Fargate em subnet privada, ALB na pública, RDS sem rota para a internet._

O importante no diagrama é o que **não** está exposto. Só o load balancer aceita tráfego da internet. Tasks e banco ficam em subnets privadas, sem IP público.

Isso é imposto por uma cadeia de security groups onde cada grupo libera acesso para o **grupo anterior**, não para um bloco de IPs:

```hcl
resource "aws_security_group" "ecs" {
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer.id]
  }
}

resource "aws_security_group" "rds" {
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
}
```
{: file='infra/networks.tf' }

`security_groups` no lugar de `cidr_blocks`. A 8080 só aceita quem vem do ALB, a 5432 só quem vem do ECS. Não há CIDR liberado, então mesmo descobrindo o endereço interno do banco não existe caminho até ele. E a regra sobrevive a renumeração de subnets, porque aponta para uma identidade e não para um intervalo que alguém precisa lembrar de atualizar.

---

## Access Key vazada continua válida

O jeito tradicional de dar acesso à AWS para um pipeline é criar um usuário IAM e salvar o Access Key como secret. O problema é o ciclo de vida: aquela chave não expira. Se vazar num log, num fork ou no histórico de um commit, continua válida até alguém perceber e revogar na mão. O intervalo entre o vazamento e a revogação é sorte.

O OIDC inverte isso. O GitHub emite um token assinado descrevendo quem está rodando o job, e a AWS troca esse token por credenciais que expiram em minutos. Nenhum segredo de longa duração fica armazenado.

No workflow são duas linhas de permissão e um step:

```yaml
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_GITHUB_OIDC_ROLE_ARN }}
          aws-region: us-east-1
```
{: file='.github/workflows/ci-cd.yml' }

O `id-token: write` autoriza o job a pedir o token, e fica declarado por job para que o de testes não tenha essa capacidade. O `AWS_GITHUB_OIDC_ROLE_ARN` não é segredo de verdade: é o ARN de uma role, um identificador público. Se vazar, sozinho não serve de nada, porque quem manda é a trust policy do outro lado.

No Terraform, primeiro registra-se o GitHub como emissor confiável:

```hcl
resource "aws_iam_openid_connect_provider" "github_oidc" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
```
{: file='infra/github-oidc.tf' }
{: .nolineno }

Depois a role, com a condição que faz o trabalho todo:

```hcl
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github-repo}:ref:refs/heads/main",
              "repo:${var.github-repo}:pull_request"
            ]
          }
        }
```
{: file='infra/iam.tf' }

O `aud` confirma que o token foi emitido para o STS da AWS. O `sub` descreve **quem** pede: o GitHub preenche esse campo com o repositório e a referência que dispararam o job.

Sem essa condição, qualquer workflow de qualquer repositório do GitHub poderia assumir sua role. O provider apenas diz que o GitHub é um emissor confiável; é o `sub` que separa "confio no GitHub" de "confio neste repositório, nesta branch".

> A segunda entrada existe porque o pipeline de infra roda `terraform plan` em pull requests para comentar o plano no PR. Pull request tem um `sub` diferente de push, então precisa ser autorizado explicitamente.
{: .prompt-info }

---

## O paradoxo do bootstrap

Aqui está a parte que não aparece no tutorial: o Terraform que cria a role OIDC precisa de credenciais para rodar a primeira vez.

É ovo e galinha em duas camadas. O pipeline só autentica se a role existir, e a role só existe se alguém rodar o Terraform. Mas o Terraform também precisa guardar o state em algum lugar, e esse lugar é um bucket S3 que também precisa ser criado antes.

O bucket sai de um Terraform separado, que usa state local justamente por ainda não ter onde guardá-lo:

```hcl
terraform {
  backend "s3" {
    bucket = "tfstate-backend-<account-id>"
    key    = "budgetplanner/state/terraform.tfstate"
    region = "us-east-1"
  }
}
```
{: file='infra/backend.tf' }
{: .nolineno }

A saída foi assumir o bootstrap manual e documentá-lo como etapa única, em vez de fingir que o pipeline cria tudo do zero:

1. `cd infra/bootstrap && terraform apply` cria o bucket do state, com credenciais locais.
2. `cd infra && terraform apply` cria o resto, incluindo o OIDC provider e a role.
3. O ARN da role vira o secret `AWS_GITHUB_OIDC_ROLE_ARN` no GitHub.
4. A partir daqui o pipeline se sustenta sozinho.

Numa conta nova, esses quatro passos precisam ser refeitos. Não dá para automatizar sem já ter uma credencial, que é justamente o que se está tentando eliminar.

O ponto honesto: o state do bootstrap ficou local e commitado. Como descreve apenas um bucket vazio, o risco é baixo, mas é uma inconsistência real com o resto do desenho e prefiro registrá-la a deixar passar.

---

## Secrets que não passam pelo state

O state do Terraform guarda em texto tudo que os recursos retornam. Declare uma senha no `.tf` e ela está no state, que está num bucket.

O RDS resolve isso gerando a senha do lado da AWS:

```hcl
resource "aws_db_instance" "budgetplanner-db" {
  engine                      = "postgres"
  engine_version              = "18.4"
  instance_class              = "db.t4g.micro"
  username                    = "postgres"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
}
```
{: file='infra/rds.tf' }

O `manage_master_user_password = true` faz a AWS criar a senha e guardá-la no Secrets Manager. Não existe atributo de senha no código nem no state, só uma referência ao ARN.

A task definition consome esse secret sem que o valor passe pelo Terraform:

```hcl
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_db_instance.budgetplanner-db.master_user_secret[0].secret_arn}:password::"
        }
      ]
```
{: file='infra/ecs.tf' }

A diferença entre `environment` e `secrets` é onde a resolução acontece. O que está em `environment` é literal e visível em qualquer `describe-task-definition`. O que está em `secrets` é um ponteiro: o agente do ECS busca o valor na hora de subir o container. O sufixo `:password::` seleciona um campo do JSON, evitando injetar o documento inteiro.

---

## O alarme que você não aprende a ignorar

Sem log group configurado, os logs do container existem só enquanto a task vive. A cada deploy some tudo, inclusive o rastro do problema que causou o restart.

O alarme mais útil é o de 5xx no ALB:

```hcl
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.application_load_balancer.arn_suffix
    TargetGroup  = aws_lb_target_group.budgetplanner-tg.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
```
{: file='infra/cloudwatch.tf' }

Três detalhes fazem a diferença entre um alarme útil e um que ninguém lê.

`treat_missing_data = "notBreaching"` trata ausência de dados como estado saudável. Num projeto sem tráfego constante, muitos minutos não têm requisição nenhuma, e o padrão do CloudWatch trataria isso como dado faltante, gerando ruído.

`ok_actions` avisa quando normaliza. Sem isso você é notificado de que quebrou e precisa ir ao console descobrir se voltou.

As dimensões usam `arn_suffix`, não `arn`, porque é o formato que as métricas do ALB esperam. Com o ARN completo o alarme é criado sem erro e simplesmente nunca encontra dado.

---

## A conta que chega mesmo com zero tráfego

Essa foi a lição que menos esperava. A observabilidade sai barata: métricas nativas gratuitas, SNS gratuito até mil notificações, dashboard gratuito, o alarme a US$0,10, mais alguns dólares de logs. Abaixo de US$5 por mês.

Já a infraestrutura:

| Item | Custo mensal aproximado |
|---|---|
| AWS Fargate (2 tasks, 0.5 vCPU / 1GB, 730h) | US$36,04 |
| Amazon RDS for PostgreSQL (`db.t4g.micro`, 10GB) | US$13,98 |
| Elastic Load Balancing (1 ALB) | US$16,45 |
| NAT Gateway (taxa fixa, subnets privadas) | ~US$33,00 |
| **Total estimado** | **~US$99,50/mês** |

Cerca de cem dólares por mês para uma API que não recebe requisição nenhuma. Duas tasks, um load balancer e um banco gerenciado cobram por hora de existência, não por uso.

O item que mais me pegou foi o NAT Gateway. Ele não parece importante no desenho e é o segundo mais caro. Existe por um motivo específico: recursos em subnet privada não têm rota para a internet, mas o ECS precisa alcançar o ECR para baixar a imagem. O NAT dá essa saída sem permitir entrada.

Ou seja, colocar o ECS em subnet privada, que é a decisão de segurança correta, é o que traz os US$33. Segurança e custo são a mesma linha do Terraform aqui.

> A estimativa não considera free tier. Fargate nunca teve cota gratuita, e RDS e ALB só têm doze meses grátis em conta nova. É por isso que o valor costuma surpreender quem calculou baseado em experiências antigas com EC2.
{: .prompt-info }

Existem saídas: VPC endpoints para o ECR no lugar do NAT, uma task só, ou App Runner em vez de ECS. Todas mudam o desenho. Escolhi manter o desenho e pagar, porque o objetivo era aprender o formato de produção, não otimizar a conta.

---

## Conclusão

Nenhuma decisão isolada é a lição. O que mudou meu jeito de trabalhar foi escrever o porquê ao lado do como e registrar **onde cada escolha quebra**. O parágrafo mais útil da documentação do projeto não é o que explica como algo funciona, é o que admite o limite: o state do bootstrap commitado, o NAT que existe por segurança e custa caro.

E a ressalva: tratar projeto pessoal como produção não é recomendação universal. Se o objetivo é validar uma ideia rápido, cem dólares por mês em infra parada é dinheiro mal gasto, e um container numa VM barata resolve. Paguei essa conta porque queria entender o formato com as mãos, não porque todo projeto pessoal precisa disso.

Se for por esse caminho, defina antes o que quer aprender. É o que separa aprendizado de uma fatura recorrente que você esquece de cancelar.

No [próximo post](/posts/api-stateless-ecs-jwt-isolamento-rate-limit/) vejo o outro lado: por que rodar duas tasks atrás de um ALB determinou o desenho da autenticação da API.

---

## Referências Técnicas

* [Repositório do Budget Planner](https://github.com/rogerbertan/budget-planner) - Código completo da API e do Terraform, com as decisões documentadas no README.
* [Guia de Deploy do projeto](https://github.com/rogerbertan/budget-planner/blob/main/docs/deploy.md) - Provisionamento passo a passo, o bootstrap manual e o troubleshooting dos erros mais comuns.
* [Documentação de CI/CD do projeto](https://github.com/rogerbertan/budget-planner/blob/main/docs/ci-cd.md) - Os dois workflows e a análise do problema de ovo e galinha.
* [Documentação de Observabilidade do projeto](https://github.com/rogerbertan/budget-planner/blob/main/docs/observability.md) - Alarmes, dashboard e a memória de cálculo das tabelas de custo.
* [Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) - Documentação do GitHub sobre os claims do token e as condições da trust policy.
* [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials) - Action que troca o token OIDC por credenciais temporárias.
* [Passing sensitive data to an ECS container](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data.html) - Como o campo `secrets` resolve valores do Secrets Manager.
* [AWS Pricing Calculator](https://calculator.aws/#/) - Ferramenta usada para levantar as estimativas de custo.

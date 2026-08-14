# rogerbertan.github.io

Blog pessoal, publicado em <https://rogerbertan.github.io>.

Construído com [Jekyll](https://jekyllrb.com/) e o tema
[Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy).

## Requisitos

- Ruby 3.3 (fixado em `.ruby-version`, gerenciado via [rbenv](https://github.com/rbenv/rbenv))

O tema vem da gem `jekyll-theme-chirpy`, então não há passo de build de assets.

## Rodando localmente

```bash
make install    # bundle install
make serve      # sobe o servidor em http://localhost:4000
make test       # builda em modo produção e valida com htmlproofer
```

`make help` lista todos os comandos.

## Escrevendo

Posts vão em `_posts/`, nomeados como `AAAA-MM-DD-titulo.md`. Rascunhos ficam em
`_drafts/` e não são publicados. Para visualizá-los localmente, use
`bundle exec jekyll serve --drafts`.

Front matter mínimo:

```yaml
---
title: Título do post
date: 2026-01-01 10:00:00 -0300
categories: [Categoria, Subcategoria]
tags: [tag1, tag2]
---
```

## Deploy

O push para `main` dispara o workflow `.github/workflows/pages-deploy.yml`,
que builda e publica no GitHub Pages.

## Licença

O tema Chirpy é MIT, © 2019 Cotes Chung. Veja [LICENSE](LICENSE).
O conteúdo dos posts é © Roger Bertan.

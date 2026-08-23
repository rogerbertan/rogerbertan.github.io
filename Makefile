SHELL := /bin/bash
RBENV_INIT := export PATH="/opt/homebrew/bin:$$HOME/.rbenv/shims:$$PATH" && eval "$$(rbenv init -)" &&

.PHONY: help serve build clean install test dev prod

help:
	@echo "Comandos disponíveis:"
	@echo "  make serve     - Roda o servidor de desenvolvimento"
	@echo "  make build     - Gera o site estático de produção"
	@echo "  make clean     - Limpa arquivos temporários"
	@echo "  make install   - Instala dependências"
	@echo "  make test      - Builda e valida o site com htmlproofer"
	@echo "  make help      - Mostra esta ajuda"

serve:
	@lsof -ti :4000 | xargs kill -9 2>/dev/null; true
	@echo "Iniciando servidor de desenvolvimento..."
	@echo "Acesse: http://localhost:4000"
	@echo "Para parar: Ctrl+C"
	@$(RBENV_INIT) bundle exec jekyll serve --port 4000

build:
	@echo "Gerando site estatico..."
	@$(RBENV_INIT) JEKYLL_ENV=production bundle exec jekyll build
	@echo "Site gerado em _site/"

clean:
	@echo "Limpando arquivos temporarios..."
	@rm -rf _site/
	@rm -rf .jekyll-cache/
	@echo "Limpeza concluida"

install:
	@echo "Instalando dependencias..."
	@$(RBENV_INIT) bundle install
	@echo "Dependencias instaladas"

test:
	@echo "Testando o site..."
	@$(RBENV_INIT) bash tools/test.sh
	@echo "Site testado com sucesso"

dev: clean serve

prod: clean build
	@echo "Site pronto para produção em _site/"

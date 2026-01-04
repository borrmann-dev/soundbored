.PHONY: help dev dev.docker dev.stop test lint format build deploy logs shell clean

# Default target
help:
	@echo "Soundbored - Development Commands"
	@echo ""
	@echo "Local Development (requires Elixir installed):"
	@echo "  make setup       - Install dependencies, setup DB, build assets"
	@echo "  make dev         - Start development server"
	@echo "  make dev.iex     - Start development server with IEx shell"
	@echo ""
	@echo "Docker Development:"
	@echo "  make docker.dev  - Start development container"
	@echo "  make docker.stop - Stop development container"
	@echo "  make docker.logs - Show container logs"
	@echo "  make docker.shell - Shell into container"
	@echo "  make docker.test - Run tests in container"
	@echo ""
	@echo "Testing & Quality:"
	@echo "  make test        - Run tests"
	@echo "  make test.watch  - Run tests in watch mode"
	@echo "  make coverage    - Run tests with coverage report"
	@echo "  make lint        - Run Credo linter"
	@echo "  make format      - Format code"
	@echo "  make format.check - Check formatting"
	@echo "  make ci          - Run all CI checks (format, lint, test)"
	@echo ""
	@echo "Production:"
	@echo "  make build       - Build production Docker image"
	@echo "  make deploy      - Deploy to Kubernetes via Helm"
	@echo "  make logs        - Show production logs"
	@echo ""
	@echo "Utilities:"
	@echo "  make deps        - Update dependencies"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make secret      - Generate SECRET_KEY_BASE"

# ============================================
# Local Development
# ============================================

setup:
	mix setup

dev:
	mix phx.server

dev.iex:
	iex -S mix phx.server

# ============================================
# Docker Development
# ============================================

docker.dev:
	docker compose -f docker-compose.dev.yml up --build

docker.dev.detach:
	docker compose -f docker-compose.dev.yml up -d --build

docker.stop:
	docker compose -f docker-compose.dev.yml down

docker.logs:
	docker compose -f docker-compose.dev.yml logs -f

docker.shell:
	docker compose -f docker-compose.dev.yml exec soundbored /bin/sh

docker.test:
	docker compose -f docker-compose.dev.yml exec soundbored mix test

docker.clean:
	docker compose -f docker-compose.dev.yml down -v

# ============================================
# Testing & Quality
# ============================================

test:
	mix test

test.watch:
	mix test.watch

coverage:
	mix coveralls.html
	@echo "Coverage report: cover/excoveralls.html"

lint:
	mix credo --strict

format:
	mix format

format.check:
	mix format --check-formatted

ci: format.check lint test

# ============================================
# Production
# ============================================

build:
	docker build -t ghcr.io/borrmann-dev/soundbored:latest .

deploy:
	./helm/upgrade.sh

logs:
	kubectl logs -n soundbored deployment/soundbored -f --tail=100

k8s.status:
	kubectl get pods -n soundbored
	kubectl get pvc -n soundbored

k8s.shell:
	kubectl exec -it -n soundbored deployment/soundbored -- /bin/sh

k8s.restart:
	kubectl rollout restart deployment/soundbored -n soundbored

# ============================================
# Utilities
# ============================================

deps:
	mix deps.get

deps.update:
	mix deps.update --all

clean:
	rm -rf _build deps
	rm -rf assets/node_modules

secret:
	@openssl rand -base64 48

# Generate .env from example
env:
	@if [ ! -f .env ]; then \
		echo "Creating .env file..."; \
		echo "DISCORD_TOKEN=" > .env; \
		echo "DISCORD_CLIENT_ID=" >> .env; \
		echo "DISCORD_CLIENT_SECRET=" >> .env; \
		echo "SECRET_KEY_BASE=$$(openssl rand -base64 48)" >> .env; \
		echo "PHX_HOST=localhost" >> .env; \
		echo "SCHEME=http" >> .env; \
		echo ".env created! Please fill in your Discord credentials."; \
	else \
		echo ".env already exists"; \
	fi

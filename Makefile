SHELL := /bin/bash

# Production runs the self-contained compose.yaml (release image):
#     make prod-up
# Development overlays it with compose.dev.yaml (hot reload):
#     make dev-up

.PHONY: prod-up prod-down prod-logs dev-up dev-down dev-logs \
        admin-bootstrap admin-transfer admin-reset test ui-test precommit

## Production ---------------------------------------------------------------

prod-up: ## Build and start the production stack in the background
	docker compose up -d --build

prod-down: ## Stop the production stack (data is kept in the volume)
	docker compose down

prod-logs: ## Follow production logs
	docker compose logs -f --tail=200

## Development ---------------------------------------------------------------

dev-up: ## Build and start the development stack with hot reload
	docker compose -f compose.yaml -f compose.dev.yaml up --build

dev-down: ## Stop the development stack
	docker compose -f compose.yaml -f compose.dev.yaml down

dev-logs: ## Follow development logs
	docker compose -f compose.yaml -f compose.dev.yaml logs -f --tail=200

## Administration -------------------------------------------------------------

admin-bootstrap: ## Create the first admin invitation (make admin-bootstrap LOGIN=alice NAME="Alice")
	docker compose exec web bin/orbit-admin bootstrap --login $(LOGIN) --name $(NAME)

admin-transfer: ## Transfer admin to an existing user (make admin-transfer LOGIN=alice)
	docker compose exec web bin/orbit-admin transfer --to-login $(LOGIN)

admin-reset: ## Generate a password-reset invitation for the admin
	docker compose exec web bin/orbit-admin reset

## Quality checks -------------------------------------------------------------

test: ## Run the test suite inside the web container
	docker compose -f compose.yaml -f compose.dev.yaml exec web mix test

ui-test: ## Run Chromium UI and accessibility tests in an isolated stack
	docker compose -f compose.e2e.yaml up --build --abort-on-container-exit --exit-code-from e2e e2e

precommit: ## Run unit checks, then isolated UI and accessibility tests
	docker compose -f compose.yaml -f compose.dev.yaml exec web mix precommit
	$(MAKE) ui-test

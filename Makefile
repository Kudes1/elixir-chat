SHELL := /bin/bash

# This branch is production-only. compose.yaml is a self-contained production
# stack and is started with a single command:
#     make prod-up     (or: docker compose up -d --build)
# Development happens on the `dev` branch.

.PHONY: prod-up prod-down prod-logs \
        admin-bootstrap admin-transfer admin-reset

## Production ---------------------------------------------------------------

prod-up: ## Build and start the production stack in the background
	docker compose up -d --build

prod-down: ## Stop the production stack (data is kept in the volume)
	docker compose down

prod-logs: ## Follow production logs
	docker compose logs -f --tail=200

## Administration -------------------------------------------------------------

admin-bootstrap: ## Create the first admin invitation (make admin-bootstrap LOGIN=alice NAME="Alice")
	docker compose exec web bin/orbit-admin bootstrap --login $(LOGIN) --name $(NAME)

admin-transfer: ## Transfer admin to an existing user (make admin-transfer LOGIN=alice)
	docker compose exec web bin/orbit-admin transfer --to-login $(LOGIN)

admin-reset: ## Generate a password-reset invitation for the admin
	docker compose exec web bin/orbit-admin reset
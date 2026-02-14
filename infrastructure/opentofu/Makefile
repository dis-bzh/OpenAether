.PHONY: plan deploy destroy clean

# Mock credentials for unused providers
export OS_AUTH_URL := http://localhost
export OS_USERNAME := dummy
export OS_PASSWORD := dummy
export OS_PROJECT_NAME := dummy
export OUTSCALE_REGION := eu-west-2
export OUTSCALE_ACCESS_KEY := dummy
export OUTSCALE_SECRET_KEY := dummy

plan: ## Generate deployment plan
	@echo "🔍 Generating deployment plan..."
	tofu plan -var-file=tofu.tfvars -out=plan

deploy: plan ## Deploy infrastructure (plan + apply)
	@echo "🚀 Deploying infrastructure..."
	tofu apply "plan"
	@echo "✅ Deployment complete!"
	@echo ""
	@echo "📋 Extracting credentials..."
	@tofu output -raw talosconfig > talosconfig 2>/dev/null || true
	@tofu output -raw kubeconfig > kubeconfig 2>/dev/null || true
	@echo "✅ Credentials saved to talosconfig and kubeconfig"

destroy: ## Destroy all infrastructure
	@echo "🗑️  Destroying infrastructure..."
	tofu destroy -var-file=tofu.tfvars

clean: ## Clean up generated files
	@echo "🧹 Cleaning up..."
	rm -f plan talosconfig kubeconfig

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

.PHONY: plan deploy destroy clean render-manifests

plan: ## Generate deployment plan
	@echo "🔍 Generating deployment plan..."
	tofu plan -var-file=tofu.tfvars -out=plan

deploy: plan ## Deploy infrastructure (plan + apply)
	@echo "🚀 Deploying infrastructure..."
	tofu apply "plan"
	@echo "✅ Deployment complete!"
	@echo ""
	@echo "📋 Config files saved to:"
	@echo "   talosconfig  → ./talosconfig"
	@echo "   kubeconfig   → ./kubeconfig"

destroy: ## Destroy all infrastructure
	@echo "🗑️  Destroying infrastructure..."
	tofu destroy -var-file=tofu.tfvars

clean: ## Clean up generated files
	@echo "🧹 Cleaning up..."
	rm -f plan talosconfig kubeconfig

render-manifests: ## Render/update bootstrap manifests (Cilium, ArgoCD)
	@echo "🔧 Rendering bootstrap manifests..."
	../../scripts/render-bootstrap-manifests.sh

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

# Hi-Terms 本地开发 Makefile
# 用法: make help

SCHEME      = HiTerms
DESTINATION = platform=macOS
DERIVED_DATA = build/DerivedData

XCODEBUILD = xcodebuild -scheme $(SCHEME) \
             -destination '$(DESTINATION)' \
             -derivedDataPath $(DERIVED_DATA)

.PHONY: help build build-release test test-unit lint ci clean generate

help: ## 显示所有可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Debug 构建
	$(XCODEBUILD) build

build-release: ## Release 构建
	$(XCODEBUILD) -configuration Release build

test: ## 运行全部测试
	$(XCODEBUILD) test

test-unit: ## 仅运行单元测试（跳过集成测试）
	$(XCODEBUILD) test \
		-skip-testing IntegrationTests

lint: ## SwiftLint 检查（需 brew install swiftlint）
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --quiet; \
	else \
		echo "SwiftLint 未安装，跳过。安装: brew install swiftlint"; \
	fi

ci: build lint test ## 本地 CI：构建 + lint + 测试

clean: ## 清理构建产物
	rm -rf build/ DerivedData/
	$(XCODEBUILD) clean 2>/dev/null || true

generate: ## 重新生成 Xcode 项目
	./Tools/generate-project.sh

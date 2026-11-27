# 随手记项目开发约定

- 开始开发前阅读同目录的 [原始需求](./原始需求.md)。用户确认需求变化时，同步更新该文档。
- 实现记账和查账界面时，对照需求文档中引用的录屏，核对点按顺序、滚轮联动、保存后的返回位置和账单在原页展开的行为。
- 账本仅保存在当前 iPhone 上。开发和演示使用示例金额，真实账目留在用户设备上。
- 修改金额统计或历史数据导入时，用示例核对启用日边界，确保历史累计只计一次，周账单和分类小计仅汇总逐笔支出。
- 交互验收以用户的 iOS 26.6 真机为准。交付时说明实际验证过的环境和流程，以及仍需真机确认的部分。

## Git 提交信息

- 提交标题沿用项目已有的 Conventional Commits 格式 `type(scope): summary`。`scope` 可省略。使用小写类型和简短的英文动词短语，例如 `feat(expenses): add optional expense notes`、`fix(categories): preserve the selected category`、`docs: document the pull request workflow`。
- 普通提交和 squash 合并生成的提交都遵循这一格式。执行 `git commit` 或合并前先核对提交标题。通过 GitHub 网页 squash 合并时编辑最终提交标题，通过 `gh pr merge --squash` 合并时用 `--subject` 显式指定标题。

## Agent skills

- **Issue tracker**：新任务和规格使用 `gyh9457/pay-app` 的 GitHub Issues，由同一个 agent 通过分支和 PR 交付，历史票据保存在 `.scratch/ledger/`。参见 [任务跟踪](docs/agents/issue-tracker.md)。
- **Triage labels**：使用上游默认标签和本项目的执行状态，参见 [状态约定](docs/agents/triage-labels.md)。
- **Domain docs**：采用项目级术语表和 ADR，参见 [领域文档约定](docs/agents/domain.md)。

本轮开发以 iOS 17.5 模拟器验证，iOS 26.6 真机验收暂缓。录屏暂不可用时依据已记录的交互实现，并在交付中列出仍需对照的项目。

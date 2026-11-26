# 随手记（PayLedger）

随手记是一个使用 SwiftUI 编写的 iOS 支出账本，适用于 iOS 17.5 及以上。账本保存在设备本地，日常记账和查账可离线完成。

- 使用现金账户记录支出，支持两级分类、自定义分类，以及修改和删除流水。
- 查看周、月、年账单。周账单按大类汇总，可展开查看逐笔消费。月、年账单可展开查看按日期分组的明细。
- 可手动录入旧账的月度汇总及启用前的期初累计。它们计入相应的月、年总额，周账单和分类小计按逐笔支出计算。

## 在模拟器运行

1. 安装 Xcode 和 iOS 17.5 或更新的模拟器运行时。
2. 打开 `PayLedger.xcodeproj`，选择 `PayLedger` scheme 和一台 iPhone 模拟器。
3. 按 `⌘R` 运行，或按 `⌘U` 运行单元和 UI 测试。工程只依赖系统框架，模拟器构建无需 Apple 开发者签名。

也可以在项目根目录运行以下命令，将设备名和系统版本替换为已安装的模拟器：

```sh
xcodebuild test -project PayLedger.xcodeproj -scheme PayLedger \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'
```

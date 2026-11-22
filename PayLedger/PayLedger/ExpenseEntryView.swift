import SwiftUI

struct ExpenseEntryView: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var categoryID = ExpenseEntryView.exampleCategoryID
    @State private var errorMessage: String?

    static let exampleCategoryID = "food"

    var body: some View {
        NavigationStack {
            Form {
                Section("金额") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                Section("分类（示例）") {
                    Picker("分类", selection: $categoryID) {
                        Text("食品酒水").tag(Self.exampleCategoryID)
                        Text("交通").tag("transport")
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    HStack { Text("日期"); Spacer(); Text("今天（默认）").foregroundStyle(.secondary) }
                    HStack { Text("账户"); Spacer(); Text("现金（默认）").foregroundStyle(.secondary) }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("记一笔")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        guard let cents = AmountInput.parseCents(amountText) else {
            errorMessage = "请输入大于 0、精确到分的金额"
            return
        }
        do {
            try store.addExpense(amountCents: cents, categoryID: categoryID, date: AppClock.now)
            errorMessage = nil
            dismiss()
        } catch {
            // Keep the form, the typed amount and the selected category so the
            // user can retry; surface the failure instead of silently losing it.
            errorMessage = error.localizedDescription
        }
    }
}

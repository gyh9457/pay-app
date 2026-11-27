import SwiftUI

struct ExpenseEntryView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @Environment(\.dismiss) private var dismiss
    private let expense: Expense?
    @State private var amountText: String
    @State private var noteText: String
    @State private var selectedDate: Date
    @State private var primaryID: String
    @State private var subcategoryID: String?
    @State private var errorMessage: String?
    @State private var isManagingCategories = false
    @State private var isChoosingCategory = false

    init(store: LedgerStore, categoryStore: CategoryStore, expense: Expense? = nil) {
        self.store = store
        self.categoryStore = categoryStore
        self.expense = expense
        let firstGroup = categoryStore.groups.first
        _amountText = State(initialValue: expense.map { Currency.format($0.amountCents) } ?? "")
        _noteText = State(initialValue: expense?.note ?? "")
        _primaryID = State(initialValue: expense?.categoryID ?? firstGroup?.id ?? "food")
        _subcategoryID = State(initialValue: expense == nil ? firstGroup?.subcategories.first?.id : expense?.subcategoryID)
        let calendar = LedgerStats.calendar
        _selectedDate = State(initialValue: expense.map {
            LedgerStats.consumptionDay(of: $0, calendar: calendar).date(in: calendar) ?? $0.date
        } ?? AppClock.now)
    }

    private var selectionLabel: String {
        let primary = categoryStore.primaryName(for: primaryID)
        if let sub = categoryStore.subcategoryName(primaryID: primaryID, subcategoryID: subcategoryID) {
            return "\(primary) · \(sub)"
        }
        return primary
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("金额") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                Section("分类") {
                    // The wheel is collapsed by default per the original flow:
                    // tap 分类 → the two-column wheel rises from the bottom →
                    // the form's selection label syncs while choosing → 完成
                    // collapses the sheet and keeps the chosen values.
                    Button { isChoosingCategory = true } label: {
                        HStack {
                            Text("分类")
                            Spacer()
                            Text(selectionLabel).foregroundStyle(.secondary)
                                .accessibilityIdentifier("categorySelection")
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("chooseCategory")

                    Button("管理分类") { isManagingCategories = true }
                }
                Section("备注") {
                    TextField("选填", text: $noteText)
                        .accessibilityLabel("备注")
                        .accessibilityIdentifier("expenseNote")
                }
                Section {
                    if expense != nil {
                        DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                            .environment(\.calendar, LedgerStats.calendar)
                            .environment(\.timeZone, LedgerStats.calendar.timeZone)
                    } else {
                        HStack { Text("日期"); Spacer(); Text("今天（默认）").foregroundStyle(.secondary) }
                    }
                    HStack { Text("账户"); Spacer(); Text("现金（默认）").foregroundStyle(.secondary) }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(expense == nil ? "记一笔" : "修改流水")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                }
            }
            .sheet(isPresented: $isManagingCategories) {
                CategoryManagementView(store: categoryStore)
            }
            .sheet(isPresented: $isChoosingCategory) {
                CategoryWheelSheet(categoryStore: categoryStore,
                                   primaryID: $primaryID,
                                   subcategoryID: $subcategoryID,
                                   allowsNoSubcategory: expense != nil)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: categoryStore.groups) { previousGroups, _ in
                // Adding the first child of the selected primary (or editing
                // the tree) must update the form's selection without dropping
                // a choice that is still valid.
                if expense != nil, subcategoryID == nil,
                   previousGroups.contains(where: { $0.id == primaryID && !$0.subcategories.isEmpty }) {
                    return
                }
                reconcileSubcategory()
            }
        }
    }

    private func reconcileSubcategory() {
        subcategoryID = categoryStore.reconciledSubcategoryID(
            primaryID: primaryID, current: subcategoryID)
    }

    private func save() {
        guard let cents = AmountInput.parseCents(amountText) else {
            errorMessage = "请输入大于 0、精确到分的金额"
            return
        }
        do {
            if let expense {
                try store.updateExpense(expense, amountCents: cents, categoryID: primaryID,
                                        subcategoryID: subcategoryID, date: selectedDate, note: noteText)
            } else {
                try store.addExpense(amountCents: cents, categoryID: primaryID,
                                     subcategoryID: subcategoryID, date: AppClock.now, note: noteText)
            }
            errorMessage = nil
            dismiss()
        } catch {
            // Keep the entered values so the user can retry.
            errorMessage = error.localizedDescription
        }
    }
}

/// Bottom two-column wheel. Selection bindings are owned by the entry form,
/// so the form label updates live while the sheet is open and keeps the chosen
/// primary/subcategory after 「完成」 collapses the sheet.
struct CategoryWheelSheet: View {
    @ObservedObject var categoryStore: CategoryStore
    @Binding var primaryID: String
    @Binding var subcategoryID: String?
    var allowsNoSubcategory = false
    @Environment(\.dismiss) private var dismiss

    private var subcategories: [ExpenseSubcategory] {
        categoryStore.subcategories(in: primaryID)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("一级分类", selection: $primaryID) {
                    if !categoryStore.groups.contains(where: { $0.id == primaryID }) {
                        Text(categoryStore.primaryName(for: primaryID)).tag(primaryID)
                    }
                    ForEach(categoryStore.groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("primaryCategoryPicker")
                .onChange(of: primaryID) { _, newID in
                    // Reset the child only when the primary actually changes
                    // and the old child is no longer valid; a still-valid
                    // selection is preserved.
                    subcategoryID = categoryStore.reconciledSubcategoryID(
                        primaryID: newID, current: subcategoryID)
                }

                Picker("子类", selection: Binding(
                    get: { subcategoryID ?? "" },
                    set: { subcategoryID = $0.isEmpty ? nil : $0 }
                )) {
                    if subcategories.isEmpty || allowsNoSubcategory {
                        Text("无子类").tag("")
                    }
                    ForEach(subcategories) { sub in
                        Text(sub.name).tag(sub.id)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("subcategoryPicker")
            }
            .frame(height: 200)
            .padding()
            .navigationTitle("选择分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("doneCategoryWheel")
                }
            }
        }
    }
}

/// Add and rename primary categories and subcategories. Ids are never
/// changed, so historical expenses keep their date/amount and show new names.
struct CategoryManagementView: View {
    @ObservedObject var store: CategoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftName = ""
    @State private var dialog: Dialog?
    @State private var errorMessage: String?

    private enum Dialog: Identifiable {
        case addPrimary
        case addSubcategory(String)
        case renamePrimary(String)
        case renameSubcategory(String, String)

        var id: String {
            switch self {
            case .addPrimary: return "addPrimary"
            case .addSubcategory(let p): return "addSub:\(p)"
            case .renamePrimary(let p): return "renamePrimary:\(p)"
            case .renameSubcategory(let p, let s): return "renameSub:\(p):\(s)"
            }
        }

        var title: String {
            switch self {
            case .addPrimary: return "新增大类"
            case .addSubcategory: return "新增子类"
            case .renamePrimary: return "重命名大类"
            case .renameSubcategory: return "重命名子类"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.isUnreadable {
                    Section {
                        Text("分类文件无法读取，已保留原文件且不会覆盖，请联系维护。")
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                ForEach(store.groups) { group in
                    Section(header: Text(group.name)) {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Button("改名") { present(.renamePrimary(group.id), seed: "") }
                                .accessibilityIdentifier("renamePrimary-\(group.id)")
                        }
                        ForEach(group.subcategories) { sub in
                            HStack {
                                Text(sub.name)
                                Spacer()
                                Button("改名") {
                                    present(.renameSubcategory(group.id, sub.id), seed: "")
                                }
                                .accessibilityIdentifier("renameSub-\(sub.id)")
                            }
                        }
                        Button("新增子类") { present(.addSubcategory(group.id), seed: "") }
                            .accessibilityIdentifier("addSub-\(group.id)")
                    }
                }
                Section {
                    Button("新增大类") { present(.addPrimary, seed: "") }
                        .accessibilityIdentifier("addPrimary")
                }
            }
            .navigationTitle("分类管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(dialog?.title ?? "", isPresented: Binding(
                get: { dialog != nil },
                set: { if !$0 { dialog = nil } }
            )) {
                TextField("名称", text: $draftName)
                    .accessibilityIdentifier("categoryNameField")
                Button("取消", role: .cancel) {}
                Button("保存") { commit() }
            }
        }
    }

    private func present(_ dialog: Dialog, seed: String) {
        self.dialog = dialog
        self.draftName = seed
        self.errorMessage = nil
    }

    private func commit() {
        guard let dialog else { return }
        do {
            switch dialog {
            case .addPrimary:
                try store.addPrimary(name: draftName)
            case .addSubcategory(let primaryID):
                try store.addSubcategory(primaryID: primaryID, name: draftName)
            case .renamePrimary(let primaryID):
                try store.renamePrimary(id: primaryID, to: draftName)
            case .renameSubcategory(let primaryID, let subID):
                try store.renameSubcategory(primaryID: primaryID, subcategoryID: subID, to: draftName)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        self.dialog = nil
    }
}

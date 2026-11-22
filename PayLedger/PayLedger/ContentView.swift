import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LedgerStore
    @State private var isPresentingEntry = false
    #if DEBUG
    @State private var clockTick = 0
    #endif

    var body: some View {
        // Resolve the reference date at render time, not at view init: a save
        // after midnight is summarized against the new day/week/month. AppClock
        // is pinned by the cross-midnight UI test and is the real date in prod.
        let now = AppClock.now
        #if DEBUG
        let _ = clockTick // re-evaluate the reference date when a UI test advances it
        #endif
        let paused = store.readiness == .needsRecovery
        NavigationStack {
            List {
                // A persistent status banner. Recovery is decided at launch,
                // before accounting opens, so this never flickers mid-session.
                if paused {
                    Section {
                        Text("账本暂需恢复，记账已暂停。请重新打开应用重试。")
                            .foregroundStyle(.orange)
                    }
                } else if store.readiness == .cleanupPending {
                    Section {
                        Text("旧账本副本待清理")
                            .foregroundStyle(.orange)
                    }
                }
                Section("支出摘要（示例）") {
                    summaryRow("今天", interval: LedgerStats.dayInterval(containing: now))
                    summaryRow("本周", interval: LedgerStats.weekInterval(containing: now))
                    summaryRow("本月", interval: LedgerStats.monthInterval(containing: now))
                }
                Section("逐笔支出") {
                    if paused {
                        // Never show an empty/zero ledger whose integrity is
                        // unconfirmed — the recovery prompt replaces it.
                        Text("账本暂需恢复，记账已暂停。请重新打开应用重试。")
                            .foregroundStyle(.secondary)
                    } else if store.expenses.isEmpty {
                        Text("暂无记录，点下方「记一笔」开始。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.expenses) { expense in
                            HStack {
                                Text(ExpenseCategory.displayName(for: expense.categoryID))
                                Spacer()
                                Text(Currency.format(expense.amountCents))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                #if DEBUG
                if AppClock.overrideDate != nil {
                    // Only present when a UI test pinned the clock; lets the
                    // cross-midnight case advance time on the open home screen.
                    Section("测试时钟") {
                        Button("测试：推进一天") {
                            AppClock.advanceOverride(by: 1)
                            clockTick += 1
                        }
                    }
                }
                #endif
            }
            .navigationTitle("随手记")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isPresentingEntry = true } label: { Image(systemName: "plus") }
                        .disabled(paused)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { isPresentingEntry = true } label: {
                    Text("记一笔").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(paused)
                .padding()
            }
            .sheet(isPresented: $isPresentingEntry) {
                ExpenseEntryView(store: store)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ title: String, interval: DateInterval?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if store.readiness == .needsRecovery {
                Text("账本暂需恢复")
                    .foregroundStyle(.orange)
            } else if let total = interval.flatMap({ store.totalCents(in: $0) }) {
                Text(Currency.format(total))
                    .foregroundStyle(.green)
            } else {
                // Never present an overflowed/capped value as a real total.
                Text("金额超出汇总范围")
                    .foregroundStyle(.orange)
            }
        }
    }
}

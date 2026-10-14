import SwiftData
import SwiftUI
import UIKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConvertedItem.createdAt, order: .reverse) private var items: [ConvertedItem]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "还没有记录",
                    systemImage: "photo.stack",
                    description: Text("转好的实况照片会出现在这里。")
                )
            } else {
                List {
                    ForEach(items) { item in
                        HistoryRow(item: item)
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("转换记录")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(items[index])
        }
        try? modelContext.save()
    }
}

private struct HistoryRow: View {
    let item: ConvertedItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = item.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(.tertiarySystemFill)
                        .overlay(
                            Image(systemName: "livephoto")
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 58, height: 58)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(Formatters.recordTitle.string(from: item.createdAt))
                    .font(.subheadline.weight(.medium))

                Text("\(item.stillFormat.displayName) · \(item.resolutionText) · \(item.durationText) · \(item.keepsAudio ? "有声" : "无声")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(item.assetIdentifier.prefix(8)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if item.savedToLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

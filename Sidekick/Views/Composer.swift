import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Shared input bar: text, attachments (photos, camera, files), send/stop.
struct Composer: View {
    @Binding var text: String
    @Binding var attachments: [PendingAttachment]
    var placeholder: String = "What can I do for you?"
    var isRunning: Bool = false
    var canSend: Bool = true
    var onSend: () -> Void
    var onStop: () -> Void = {}

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            AttachmentChip(attachment: att) {
                                attachments.removeAll { $0.id == att.id }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Label("Photo Library", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    }
                    Button { showFileImporter = true } label: { Label("Attach File", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Attach")

                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))

                if isRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(sendEnabled ? Theme.accent : Color.secondary.opacity(0.5))
                    }
                    .disabled(!sendEnabled)
                    .accessibilityLabel("Send")
                }
            }
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                       let att = AttachmentImporter.fromImage(img) {
                        attachments.append(att)
                    }
                }
                photoItems = []
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .plainText, .commaSeparatedText, .json, .image, .text, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let att = try? AttachmentImporter.fromFile(url: url) { attachments.append(att) }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let att = AttachmentImporter.fromImage(image) { attachments.append(att) }
            }
            .ignoresSafeArea()
        }
    }

    private var sendEnabled: Bool {
        canSend && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        guard sendEnabled else { return }
        focused = false
        onSend()
    }
}

struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumb = attachment.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

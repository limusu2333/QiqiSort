import AppKit

struct PhotoNoteMenuContext { let files:[URL]; let note:()->Void }
private final class PhotoNoteMenuTarget:NSObject {
    let context:PhotoNoteMenuContext
    init(_ context:PhotoNoteMenuContext) { self.context = context }
    @objc func note() { context.note() }
    @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting(context.files) }
}
enum PhotoNoteMenu {
    static func make(_ context:PhotoNoteMenuContext)->NSMenu {
        let menu = NSMenu(), target = PhotoNoteMenuTarget(context)
        for (title,action) in [("添加/编辑备注…",#selector(PhotoNoteMenuTarget.note)),("在访达中显示",#selector(PhotoNoteMenuTarget.reveal))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = target; item.representedObject = target; menu.addItem(item)
        }; return menu
    }
}
class NoteActionsImageView:NSImageView {
    var noteMenuContext:(()->PhotoNoteMenuContext?)?
    override func menu(for event:NSEvent)->NSMenu? { noteMenuContext?().map(PhotoNoteMenu.make) ?? super.menu(for:event) }
}
final class NotedImportPhotoView:NoteActionsImageView {
    let noteButton = MemphisButton(title:"本图备注",target:nil,action:nil)
    override init(frame:NSRect) {
        super.init(frame:frame); styleButton(noteButton,symbol:"note.text"); noteButton.target = self; noteButton.action = #selector(editNote)
        addSubview(noteButton); NSLayoutConstraint.activate([noteButton.leadingAnchor.constraint(equalTo:leadingAnchor,constant:16),noteButton.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-16)])
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func editNote() { noteMenuContext?()?.note() }
}
final class ReviewPhotoCollection:NSCollectionView {
    var noteContextAt:((IndexPath)->PhotoNoteMenuContext?)?
    override func menu(for event:NSEvent)->NSMenu? {
        guard let path = indexPathForItem(at:convert(event.locationInWindow,from:nil)),let context = noteContextAt?(path) else { return super.menu(for:event) }
        return PhotoNoteMenu.make(context)
    }
}

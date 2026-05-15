import ArgumentParser
import Foundation

@main
struct DraftScript: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draftscript",
        abstract: "Interact with the Drafts app from the command line.",
        version: "1.2.0",
        subcommands: [
            InteractiveREPL.self,
            Create.self,
            List.self,
            Get.self,
            Current.self,
            TextSearch.self,
            AISearch.self,
            RunAction.self,
            SetTag.self,
            FlagDraft.self,
            Folder.self,
        ],
        defaultSubcommand: InteractiveREPL.self
    )
}

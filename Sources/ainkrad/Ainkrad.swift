import ArgumentParser

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Ainkrad: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ainkrad",
        abstract: "Scaffold, build, validate, and publish Ainkrad Apps.",
        version: "0.1.0",
        subcommands: [Doctor.self, New.self, Build.self, Validate.self, Dev.self, Publish.self,
                      Notify.self]
    )
}

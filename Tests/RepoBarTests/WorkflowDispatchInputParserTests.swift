import Foundation
@testable import RepoBarCore
import Testing

struct WorkflowDispatchInputParserTests {
    @Test
    func `parses workflow dispatch inputs`() throws {
        let yaml = """
        name: Deploy
        on:
          workflow_dispatch:
            inputs:
              environment:
                description: "Target environment"
                required: true
                type: choice
                options:
                  - staging
                  - production
              dry_run:
                description: Dry run only
                required: false
                default: "true"
                type: boolean
        """

        let inputs = try #require(WorkflowDispatchInputParser.parse(yaml))

        #expect(inputs.count == 2)
        #expect(inputs[0].name == "environment")
        #expect(inputs[0].isRequired == true)
        #expect(inputs[0].type == "choice")
        #expect(inputs[0].options == ["staging", "production"])
        #expect(inputs[1].name == "dry_run")
        #expect(inputs[1].defaultValue == "true")
        #expect(inputs[1].type == "boolean")
    }

    @Test
    func `returns empty inputs for dispatchable workflow without inputs`() throws {
        let yaml = """
        on:
          workflow_dispatch:
          push:
            branches: [main]
        """

        let inputs = try #require(WorkflowDispatchInputParser.parse(yaml))

        #expect(inputs.isEmpty)
    }

    @Test
    func `returns nil when workflow dispatch is absent`() {
        let yaml = """
        on:
          push:
            branches: [main]
        """

        #expect(WorkflowDispatchInputParser.parse(yaml) == nil)
    }
}

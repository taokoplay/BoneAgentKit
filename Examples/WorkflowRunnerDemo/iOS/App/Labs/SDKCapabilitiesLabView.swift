import SwiftUI

struct SDKCapabilitiesLabView: View {
    let workspace: LabWorkspaceModel
    var body: some View {
        LabToolWorkbenchView(workspace: workspace, showsSpecialExperiments: true)
    }
}

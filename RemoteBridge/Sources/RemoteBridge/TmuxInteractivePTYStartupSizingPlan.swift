struct TmuxInteractivePTYStartupSizingPlan: Equatable, Sendable {
    let bootstrapSize: TmuxInteractivePTYSize
    let targetSize: TmuxInteractivePTYSize

    init?(targetSize: TmuxInteractivePTYSize) {
        let bootstrapSize: TmuxInteractivePTYSize
        if targetSize.rows > 1 {
            bootstrapSize = TmuxInteractivePTYSize(
                columns: targetSize.columns,
                rows: targetSize.rows - 1
            )
        } else if targetSize.columns > 1 {
            bootstrapSize = TmuxInteractivePTYSize(
                columns: targetSize.columns - 1,
                rows: targetSize.rows
            )
        } else {
            return nil
        }

        self.bootstrapSize = bootstrapSize
        self.targetSize = targetSize
    }
}

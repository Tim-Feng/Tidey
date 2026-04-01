| type | test | seam | minimal change | commit kind | status |
| --- | --- | --- | --- | --- | --- |
| structural | `TideySidebarCloseButtonTests/*` | sidebar close button visibility/position lives in `TideySidebarTableView` + `configureTideySidebarCellView:` and needs a narrow test fixture without full app init | add a focused sidebar test fixture that injects table/cell state directly | STRUCTURAL | pass |
| behavior | `TideySidebarCloseButtonTests/testHoveredRowKeepsCloseButtonVisibleAfterSelectionChange` | existing sidebar table + cell configure path | verify hovered row close button stays visible after selection-triggered reconfigure | BEHAVIORAL | pass |
| behavior | `TideySidebarCloseButtonTests/testCloseButtonVerticalPositionIsFixedAcrossRowLayouts` | existing `configureTideySidebarCellView:` layout path | verify close button y stays fixed with/without body/status content | BEHAVIORAL | pass |
| behavior | `TideySessionFactoryLaunchCommandTests/testComputeCommandWrapsStandardLoginCommandThroughTideyLaunchCommand` | request-level `computeCommandWithCompletion` path | verify session factory wraps standard login command before launch | BEHAVIORAL | pass |

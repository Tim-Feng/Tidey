| type | test | seam | minimal change | commit kind | status |
| --- | --- | --- | --- | --- | --- |
| structural | `TideyRightPanelTabGroupingTests/testEditorTabsDefaultToEditorKind` | right-panel tabs need an explicit kind so editor/browser tabs can share one strip without changing selection plumbing | add a right-panel tab kind model and a pure grouping helper | STRUCTURAL | in_progress |
| behavior | `TideyRightPanelTabGroupingTests/testMixedRightPanelTabsGroupByKind` | mixed tab kinds should render as grouped runs in the right tab strip | lay out tabs in kind groups with a visible gap between groups | BEHAVIORAL | todo |
| behavior | `TideyRightPanelTabGroupingTests/testEditorTabsStayInSingleGroupInOriginalOrder` | current editor tabs must keep their existing selection/close behavior under the generic right-panel model | keep editor tab loading, selection, and close actions stable while using the new grouping seam | BEHAVIORAL | todo |

// Closes KWin's debug console if a probe left it open.
for (const w of workspace.windowList()) {
  if (w.caption === "Debug Console") w.closeWindow();
}

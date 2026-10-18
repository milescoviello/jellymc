// Lists the windows KWin manages, for checking that the app's window is really mapped.
for (const w of workspace.windowList()) {
  console.warn("JMCWIN " + w.resourceClass + " | " + w.caption + " | " + JSON.stringify(w.frameGeometry) + " minimized=" + w.minimized + " normal=" + w.normalWindow);
}

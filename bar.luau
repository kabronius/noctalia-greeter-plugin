--!nonstrict
-- Bar entry point: opens the Greeter Settings panel.

function update()
  noctalia.setUpdateInterval(600000)
  barWidget.setGlyph(noctalia.getConfig("glyph"))
  barWidget.setTooltip(noctalia.tr("bar.tooltip"))
end

function onClick()
  noctalia.togglePanel("kabronius/greeter-settings:panel")
end

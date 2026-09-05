# 1.1.0 - 2026-09-06

- Preserve offline inventory and show current / remembered counts.
- Scan Accessibility off the UI thread; retry after launches and wake.
- Improve system module detection and display geometry filtering.
- Honor native toggle sections; migrate the app control to Shown once.
- Anchor Quick Bar to the native button, activate menus through Accessibility, and exclude Always Hidden items.
- Close windows with Command-W without terminating the menu bar app.
- Handle duplicate AI IDs, preserve the actual Before layout, and report asynchronous layout results.
- Add scrollable lanes and persistence error feedback.

Validation: release compilation and signature checks. Automated tests omitted at the maintainer's request. The download is ad-hoc signed and is not Apple notarized.

# Changelog

## 1.0.0-beta · 2026-09-01

This release replaces the former Open Notch implementation with the new OPEN BAR / 若栏 architecture and interface.

- Native Apple silicon macOS app with a single translucent glass workspace.
- Three visibility sections that mirror the live macOS menu bar order.
- Automatic visibility application after drag-and-drop changes.
- Adaptive icon grid that wraps to additional rows in smaller windows.
- Native in-window traffic lights and draggable borderless window surface.
- Compact status-bar quick bar for hidden items.
- AI placement with Before / After review, DeepSeek support, and local fallback.
- English and Simplified Chinese interface and product-name localization.
- OneDrive identity stability, layout guardian, diagnostics, and policy persistence.

### Compatibility

- Apple silicon (arm64)
- macOS 14 or later
- Accessibility permission required for menu bar inspection and visibility management

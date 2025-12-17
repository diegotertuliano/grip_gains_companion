import Foundation

/// JavaScript code snippets for interacting with the gripgains.ca web UI
enum JavaScriptBridge {
    /// Click the fail button
    static let clickFailButton = """
        (function() {
            const button = document.querySelector('button.btn-fail-prominent');
            if (button && !button.disabled) {
                button.click();
            }
        })();
    """

    /// Check if fail button is enabled
    static let checkFailButtonState = """
        (function() {
            const button = document.querySelector('button.btn-fail-prominent');
            const enabled = button && !button.disabled;
            window.webkit.messageHandlers.buttonState.postMessage(enabled);
        })();
    """

    /// MutationObserver script for real-time button state changes
    static let observerScript = """
        (function() {
            function setupObserver() {
                const button = document.querySelector('button.btn-fail-prominent');
                if (!button) {
                    // Button not ready, retry in 100ms
                    setTimeout(setupObserver, 100);
                    return;
                }

                const observer = new MutationObserver(function() {
                    window.webkit.messageHandlers.buttonState.postMessage(!button.disabled);
                });

                // Watch ONLY the button, not entire body
                observer.observe(button, {
                    attributes: true,
                    attributeFilter: ['disabled', 'class']
                });

                // Initial state
                window.webkit.messageHandlers.buttonState.postMessage(!button.disabled);
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupObserver);
            } else {
                setupObserver();
            }
        })();
    """

    /// Scrape target weight from the session preview header
    static let scrapeTargetWeight = """
        (function() {
            const elements = document.querySelectorAll('.session-preview-header .text-white');
            for (const elem of elements) {
                const text = elem.textContent.trim();
                if (text.includes('kg') || text.includes('lbs') || text.includes('lb')) {
                    window.webkit.messageHandlers.targetWeight.postMessage(text);
                    return;
                }
            }
            window.webkit.messageHandlers.targetWeight.postMessage(null);
        })();
    """

    /// MutationObserver script for real-time target weight changes
    static let targetWeightObserverScript = """
        (function() {
            function scrapeAndSendWeight() {
                const elements = document.querySelectorAll('.session-preview-header .text-white');
                for (const elem of elements) {
                    const text = elem.textContent.trim();
                    if (text.includes('kg') || text.includes('lbs') || text.includes('lb')) {
                        window.webkit.messageHandlers.targetWeight.postMessage(text);
                        return;
                    }
                }
                window.webkit.messageHandlers.targetWeight.postMessage(null);
            }

            function setupTargetWeightObserver() {
                const previewHeader = document.querySelector('.session-preview-header');
                if (!previewHeader) {
                    // Preview not ready, retry in 500ms
                    setTimeout(setupTargetWeightObserver, 500);
                    return;
                }

                const observer = new MutationObserver(function() {
                    scrapeAndSendWeight();
                });

                // Watch for changes in the preview header
                observer.observe(previewHeader, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });

                // Send initial value
                scrapeAndSendWeight();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupTargetWeightObserver);
            } else {
                setupTargetWeightObserver();
            }
        })();
    """
}

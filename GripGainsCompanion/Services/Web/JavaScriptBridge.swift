import Foundation

/// JavaScript code snippets for interacting with the gripgains.ca web UI
enum JavaScriptBridge {
    /// Close the weight picker if it's open on page load
    /// This handles the case where Vue restores the picker state after a page refresh
    static let closePickerOnLoadScript = """
        (function() {
            function closePickerIfOpen() {
                const picker = document.querySelector('.weight-picker-modal');
                if (picker) {
                    const closeBtn = picker.querySelector('.close-button');
                    if (closeBtn) closeBtn.click();
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', closePickerIfOpen);
            } else {
                closePickerIfOpen();
            }
        })();
    """

    /// Patch Date.now() and timer functions to account for background time
    /// Must be injected at document start before any other scripts run
    static let backgroundTimeOffsetScript = """
        (function() {
            let offset = 0;
            const originalDateNow = Date.now;
            const originalSetInterval = window.setInterval;
            const originalDateGetTime = Date.prototype.getTime;

            // Track active intervals for catch-up ticks
            const activeIntervals = new Map();

            // Track timer state at background start
            let timerElapsedAtBackgroundStart = 0;

            // Get elapsed time from DOM timer
            function getElapsedTime() {
                const el = document.querySelector('.elapsed-time');
                return el ? (parseInt(el.textContent.trim()) || 0) : 0;
            }

            // Called when app enters background
            window._recordBackgroundStart = function() {
                try {
                    timerElapsedAtBackgroundStart = getElapsedTime();
                } catch (e) {}
            };

            // Called when app resumes from background
            window._addBackgroundTime = function(ms) {
                try {
                    offset += ms;

                    // Calculate missed display ticks (JS is throttled in background)
                    const timerNow = getElapsedTime();
                    const actualAdvance = timerNow - timerElapsedAtBackgroundStart;
                    const expectedAdvance = Math.floor(ms / 1000);
                    const missedTicks = Math.max(0, expectedAdvance - actualAdvance);

                    // Fire missed ticks to update display
                    if (missedTicks > 0) {
                        activeIntervals.forEach((info) => {
                            if (info.callback) {
                                for (let i = 0; i < missedTicks; i++) {
                                    try { info.callback(); } catch (e) {}
                                }
                            }
                        });
                    }
                } catch (e) {}
            };

            // Patch Date.now to include offset
            Date.now = function() {
                return originalDateNow() + offset;
            };

            // Patch Date.prototype.getTime to include offset
            Date.prototype.getTime = function() {
                return originalDateGetTime.call(this) + offset;
            };

            // Track setInterval calls
            window.setInterval = function(callback, delay, ...args) {
                const wrappedCallback = typeof callback === 'function'
                    ? () => callback(...args)
                    : () => eval(callback);
                const id = originalSetInterval(wrappedCallback, delay);
                activeIntervals.set(id, { callback: wrappedCallback, delay: delay });
                return id;
            };

            // Clean up interval tracking
            const originalClearInterval = window.clearInterval;
            window.clearInterval = function(id) {
                activeIntervals.delete(id);
                return originalClearInterval(id);
            };
        })();
    """

    /// Patch the Web Audio API so all output routes through a togglable master gain,
    /// letting the app mute gripgains.ca's sounds. Injected at RUNTIME (via
    /// evaluateJavaScript) only when the user turns Grip Gains sounds off — gripgains.ca
    /// builds fresh nodes per sound and reconnects to destination each time, so this
    /// catches every subsequent sound without a reload. Idempotent (install guard).
    static let websiteAudioMuteScript = """
        (function() {
            if (window.__ggAudioMuteInstalled) return;
            window.__ggAudioMuteInstalled = true;
            window.__ggAudioMuted = window.__ggAudioMuted || false;

            const masterGains = [];
            window.__ggSetAudioMuted = function(muted) {
                window.__ggAudioMuted = !!muted;
                masterGains.forEach(function(g) {
                    try { g.gain.value = window.__ggAudioMuted ? 0 : 1; } catch (e) {}
                });
            };

            if (!window.AudioNode) return;
            const origConnect = AudioNode.prototype.connect;
            const masterForCtx = new WeakMap();

            AudioNode.prototype.connect = function(destination) {
                try {
                    const ctx = this.context;
                    if (ctx && destination === ctx.destination) {
                        let mg = masterForCtx.get(ctx);
                        if (!mg) {
                            mg = ctx.createGain();
                            mg.gain.value = window.__ggAudioMuted ? 0 : 1;
                            origConnect.call(mg, ctx.destination);
                            masterForCtx.set(ctx, mg);
                            masterGains.push(mg);
                        }
                        return origConnect.call(this, mg);
                    }
                } catch (e) {}
                return origConnect.apply(this, arguments);
            };
        })();
    """

    /// Apply the current mute state to the page's Web Audio graph (no-op if the patch
    /// was never installed, i.e. the user has never muted).
    static func setWebsiteAudioMuted(_ muted: Bool) -> String {
        "if (window.__ggSetAudioMuted) { window.__ggSetAudioMuted(\(muted)); }"
    }

    /// Click the fail button
    static let clickFailButton = """
        (function() {
            const button = document.querySelector('button.btn-fail-prominent');
            if (button && !button.disabled) {
                button.click();
            }
        })();
    """

    /// Click the "End Session" button to abort the session
    static let clickEndSessionButton = """
        (function() {
            const button = document.querySelector('button.btn-danger.btn-lg.session-actions-end');
            if (button && !button.disabled) {
                button.click();
            }
        })();
    """

    /// Click the "Start" button to begin the session
    static let clickStartButton = """
        (function() {
            const button = document.querySelector('button.btn-start-prominent');
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
            let currentButton = null;
            let attributeObserver = null;

            function reportButtonState() {
                const button = document.querySelector('button.btn-fail-prominent');
                const enabled = button !== null && !button.disabled;
                window.webkit.messageHandlers.buttonState.postMessage(enabled);
            }

            function watchButtonAttributes(button) {
                if (attributeObserver) {
                    attributeObserver.disconnect();
                }
                attributeObserver = new MutationObserver(function() {
                    reportButtonState();
                });
                attributeObserver.observe(button, {
                    attributes: true,
                    attributeFilter: ['disabled', 'class']
                });
            }

            function checkButton() {
                const button = document.querySelector('button.btn-fail-prominent');
                if (button && button !== currentButton) {
                    currentButton = button;
                    watchButtonAttributes(button);
                    reportButtonState();
                } else if (!button && currentButton) {
                    currentButton = null;
                    if (attributeObserver) {
                        attributeObserver.disconnect();
                        attributeObserver = null;
                    }
                    reportButtonState();
                }
            }

            function setupObserver() {
                const domObserver = new MutationObserver(function() {
                    checkButton();
                });
                domObserver.observe(document.body, {
                    childList: true,
                    subtree: true
                });
                checkButton();
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

    /// MutationObserver script for real-time target weight and duration changes
    static let targetWeightObserverScript = """
        (function() {
            // Sentinel distinct from any real value, so the first scrape always posts.
            const UNSET = {};
            let lastWeight = UNSET;
            let lastDuration = UNSET;
            let lastGripper = UNSET;
            let lastSide = UNSET;

            function scrapeAndSendValues() {
                const elements = document.querySelectorAll('.session-preview-header .text-white');
                let weight = null;
                let duration = null;

                for (const elem of elements) {
                    const text = elem.textContent.trim();

                    if (weight === null && (text.includes('kg') || text.includes('lbs') || text.includes('lb'))) {
                        weight = text;
                    }

                    if (duration === null && text.endsWith('s') && !text.includes('kg') && !text.includes('lb')) {
                        const seconds = parseInt(text);
                        if (!isNaN(seconds) && seconds > 0) {
                            duration = seconds;
                        }
                    }
                }

                if (weight !== lastWeight) {
                    window.webkit.messageHandlers.targetWeight.postMessage(weight);
                    lastWeight = weight;
                }
                if (duration !== lastDuration) {
                    window.webkit.messageHandlers.targetDuration.postMessage(duration);
                    lastDuration = duration;
                }

                const purpleElements = document.querySelectorAll('.session-preview-header .text-purple-200');
                const gripper = purpleElements.length > 0 ? purpleElements[0].textContent.trim() : null;
                const side = purpleElements.length > 1 ? purpleElements[1].textContent.trim() : null;
                if (gripper !== lastGripper || side !== lastSide) {
                    window.webkit.messageHandlers.sessionInfo.postMessage({ gripper: gripper, side: side });
                    lastGripper = gripper;
                    lastSide = side;
                }
            }

            function setupTargetObserver() {
                // Observe document.body so the observer survives Vue tearing down and
                // recreating .session-preview-header (e.g. between workouts on the same
                // session). An observer bound to a specific element instance dies once
                // Vue replaces that node.
                const observer = new MutationObserver(scrapeAndSendValues);
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });

                scrapeAndSendValues();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupTargetObserver);
            } else {
                setupTargetObserver();
            }
        })();
    """

    /// MutationObserver script to detect when advanced-settings-header visibility changes
    static let settingsVisibilityObserverScript = """
        (function() {
            let lastVisible = null;

            function checkAndSend() {
                const advancedHeader = document.querySelector('.advanced-settings-header');
                const isVisible = advancedHeader !== null && advancedHeader.offsetParent !== null;
                if (isVisible !== lastVisible) {
                    lastVisible = isVisible;
                    window.webkit.messageHandlers.settingsVisible.postMessage(isVisible);
                }
            }

            const observer = new MutationObserver(checkAndSend);
            observer.observe(document.body, { childList: true, subtree: true });

            // Initial check after DOM is ready
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', checkAndSend);
            } else {
                checkAndSend();
            }
        })();
    """

    /// Set target weight in the web UI picker (value in kg, converts to lbs if needed)
    static func setTargetWeightScript(weightKg: Double) -> String {
        """
        (function() {
            const KG_TO_LBS = 2.20462;
            const targetKg = \(weightKg);

            // Find the weight picker button
            const button = document.querySelector('.weight-picker-button');
            if (!button) return;

            // Inject CSS to hide the picker while we interact with it
            const style = document.createElement('style');
            style.id = 'auto-select-hide';
            style.textContent = '.weight-picker-modal { visibility: hidden !important; opacity: 0 !important; position: fixed !important; }';
            document.head.appendChild(style);

            // Click to open the picker
            button.click();

            // Wait for picker to render, then find options
            setTimeout(() => {
                const options = document.querySelectorAll('.weight-option');
                if (!options.length) {
                    style.remove();
                    return;
                }

                // Detect web UI unit from option text (kg vs lbs)
                const firstText = options[0].textContent.trim();
                const isLbs = firstText.toLowerCase().includes('lb');

                // Convert kg to lbs if web UI is in lbs
                const targetValue = isLbs ? targetKg * KG_TO_LBS : targetKg;

                // Find closest option
                let closest = null;
                let closestDiff = Infinity;

                options.forEach(opt => {
                    const text = opt.textContent.trim();
                    const value = parseFloat(text);
                    const diff = Math.abs(value - targetValue);
                    if (diff < closestDiff) {
                        closestDiff = diff;
                        closest = opt;
                    }
                });

                // Temporarily switch to opacity-based hiding to allow clicking
                style.textContent = '.weight-picker-modal { opacity: 0 !important; pointer-events: auto !important; }';

                // Click the closest option (Vue handles the rest)
                if (closest) closest.click();

                // Remove the hiding style after picker closes
                setTimeout(() => style.remove(), 100);
            }, 50);
        })();
        """
    }

    /// Scrape available weight options from the picker (opens picker invisibly, reads options, closes)
    static let scrapeWeightOptions = """
        (function() {
            const button = document.querySelector('.weight-picker-button');
            if (!button) {
                window.webkit.messageHandlers.weightOptions.postMessage({ weights: [], isLbs: false });
                return;
            }

            // Inject CSS to hide the modal while we interact
            const style = document.createElement('style');
            style.id = 'scrape-options-hide';
            style.textContent = '.weight-picker-modal { visibility: hidden !important; opacity: 0 !important; position: fixed !important; }';
            document.head.appendChild(style);

            // Click to open the picker
            button.click();

            // Wait for picker to render, then scrape options
            setTimeout(() => {
                const options = document.querySelectorAll('.weight-option');
                const weights = [];
                let isLbs = false;

                options.forEach(opt => {
                    const text = opt.textContent.trim().toLowerCase();
                    const value = parseFloat(text);
                    if (!isNaN(value)) {
                        weights.push(value);
                        if (text.includes('lb')) isLbs = true;
                    }
                });

                // Temporarily switch to opacity-based hiding to allow clicking
                style.textContent = '.weight-picker-modal { opacity: 0 !important; pointer-events: auto !important; }';

                // Close picker by clicking the close button
                const picker = document.querySelector('.weight-picker-modal');
                if (picker) {
                    const closeBtn = picker.querySelector('.close-button');
                    if (closeBtn) {
                        closeBtn.click();
                    } else {
                        // Fallback: try clicking button again to close
                        button.click();
                    }
                }

                // Remove the hiding style after picker closes
                setTimeout(() => style.remove(), 150);

                // Send weights with unit info
                window.webkit.messageHandlers.weightOptions.postMessage({
                    weights: weights,
                    isLbs: isLbs
                });
            }, 100);
        })();
    """

    /// MutationObserver script for real-time remaining time from timer display
    static let remainingTimeObserverScript = """
        (function() {
            const UNSET = {};
            let lastValue = UNSET;

            function scrapeAndSendRemainingTime() {
                const timerValue = document.querySelector('.timer-value');
                let seconds = null;

                if (timerValue) {
                    const text = timerValue.textContent.trim();
                    const parsed = text.startsWith('+')
                        ? -parseInt(text.substring(1))
                        : parseInt(text);
                    if (!isNaN(parsed)) {
                        seconds = parsed;
                    }
                }

                if (seconds !== lastValue) {
                    window.webkit.messageHandlers.remainingTime.postMessage(seconds);
                    lastValue = seconds;
                }
            }

            function setupRemainingTimeObserver() {
                // Observe document.body so the observer survives Vue tearing down and
                // recreating .timer-value between workouts. An observer bound to a
                // specific element instance dies once Vue replaces that node.
                const observer = new MutationObserver(scrapeAndSendRemainingTime);
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });

                scrapeAndSendRemainingTime();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupRemainingTimeObserver);
            } else {
                setupRemainingTimeObserver();
            }
        })();
    """

    /// MutationObserver script to detect "Save to Database" button appearance (end of set)
    static let saveButtonObserverScript = """
        (function() {
            let lastSaveButtonVisible = false;

            function checkSaveButton() {
                // Look for the Save to Database button by text content
                const buttons = document.querySelectorAll('button.btn.btn-primary');
                let saveButtonFound = false;

                for (const button of buttons) {
                    if (button.textContent.trim() === 'Save to Database') {
                        saveButtonFound = true;
                        break;
                    }
                }

                // Only notify on state change (button appeared)
                if (saveButtonFound && !lastSaveButtonVisible) {
                    window.webkit.messageHandlers.saveButtonAppeared.postMessage(true);
                }
                lastSaveButtonVisible = saveButtonFound;
            }

            function setupSaveButtonObserver() {
                const observer = new MutationObserver(function() {
                    checkSaveButton();
                });

                // Watch entire body for button appearance
                observer.observe(document.body, {
                    childList: true,
                    subtree: true
                });

                // Initial check
                checkSaveButton();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupSaveButtonObserver);
            } else {
                setupSaveButtonObserver();
            }
        })();
    """
}

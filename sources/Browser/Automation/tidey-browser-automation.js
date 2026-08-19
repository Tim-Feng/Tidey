if (!globalThis.tideyBrowserAutomation) {
    const elementToID = new WeakMap();
    const idToElement = new Map();
    let nextElementID = 1;

    const elementID = (element) => {
        let identifier = elementToID.get(element);
        if (!identifier) {
            identifier = `e${nextElementID++}`;
            elementToID.set(element, identifier);
            idToElement.set(identifier, element);
        }
        return identifier;
    };

    const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
    };

    const target = (identifier) => {
        const element = idToElement.get(identifier);
        return element && element.isConnected ? element : null;
    };

    const describe = (element) => {
        const rect = element.getBoundingClientRect();
        return {
            element_id: elementID(element),
            tag: element.tagName.toLowerCase(),
            role: element.getAttribute("role") || "",
            name: element.getAttribute("aria-label") || element.getAttribute("name") || "",
            text: (element.innerText || element.textContent || "").trim().slice(0, 1000),
            href: element.href || "",
            value: typeof element.value === "string" ? element.value.slice(0, 4000) : "",
            disabled: Boolean(element.disabled || element.getAttribute("aria-disabled") === "true"),
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
        };
    };

    const dispatchInput = (element) => {
        element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText" }));
        element.dispatchEvent(new Event("change", { bubbles: true }));
    };

    const perform = async (operation, argumentsObject) => {
        switch (operation) {
        case "snapshot": {
            const selector = "a[href],button,input,textarea,select,[role='button'],[role='link'],[contenteditable='true'],[tabindex]";
            const elements = Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 500).map(describe);
            return {
                title: document.title || "",
                url: location.href,
                text: (document.body?.innerText || "").slice(0, 50000),
                elements
            };
        }
        case "click": {
            const element = target(argumentsObject.element_id);
            if (!element) return { error: "target_gone" };
            element.focus();
            element.click();
            return { ok: true };
        }
        case "fill": {
            const element = target(argumentsObject.element_id);
            if (!element) return { error: "target_gone" };
            element.focus();
            if (element.isContentEditable) {
                element.textContent = argumentsObject.text;
            } else if ("value" in element) {
                element.value = argumentsObject.text;
            } else {
                return { error: "invalid_target" };
            }
            dispatchInput(element);
            return { ok: true };
        }
        case "type": {
            const element = target(argumentsObject.element_id);
            if (!element) return { error: "target_gone" };
            element.focus();
            if (element.isContentEditable) {
                element.textContent = (element.textContent || "") + argumentsObject.text;
            } else if ("value" in element) {
                element.value = (element.value || "") + argumentsObject.text;
            } else {
                return { error: "invalid_target" };
            }
            dispatchInput(element);
            return { ok: true };
        }
        case "key": {
            const element = document.activeElement || document.body;
            const options = { key: argumentsObject.key, bubbles: true, cancelable: true };
            element.dispatchEvent(new KeyboardEvent("keydown", options));
            element.dispatchEvent(new KeyboardEvent("keyup", options));
            if (argumentsObject.key === "Enter" && element.form) element.form.requestSubmit();
            return { ok: true };
        }
        case "scroll":
            window.scrollBy(argumentsObject.delta_x, argumentsObject.delta_y);
            return { ok: true, x: window.scrollX, y: window.scrollY };
        case "contains_text":
            return { found: (document.body?.innerText || "").includes(argumentsObject.text) };
        default:
            return { error: "unsupported_operation" };
        }
    };

    globalThis.tideyBrowserAutomation = { perform };
}

return await globalThis.tideyBrowserAutomation.perform(operation, argumentsObject);

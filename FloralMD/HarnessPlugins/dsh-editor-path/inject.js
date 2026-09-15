// dsh-editor-path: insert the host's current editor document path into the
// dsh composer (a React-controlled textarea). Bundled resource invoked via
// evaluateJavaScript as `(<this source>)(<json-path>)`.
function (path) {
	'use strict';
	var ta = document.querySelector('textarea');
	if (!ta) {
		return { ok: false, reason: 'no-textarea' };
	}
	var setter = Object.getOwnPropertyDescriptor(
		window.HTMLTextAreaElement.prototype,
		'value'
	).set;
	var current = ta.value;
	var insert = current.length === 0 ? path : current + '\n' + path;
	setter.call(ta, insert);
	// React 受控组件需要原生 setter + input 事件才会更新状态。
	ta.dispatchEvent(new Event('input', { bubbles: true }));
	ta.focus();
	return { ok: true };
}

import assert from "node:assert/strict";
import test from "node:test";
import { originalImageRequestForPointer } from "../src/image-context.js";

const file = { mimeType: "image/png", dataURL: "data:image/png;base64,AA==" };
const event = { clientX: 12, clientY: 34 };

test("returns original binary only for a right-click image hit", () => {
  const request = originalImageRequestForPointer(
    2,
    { hit: { element: { type: "image", fileId: "file-1" } } },
    { "file-1": file },
    event
  );
  assert.deepEqual(request, { fileId: "file-1", ...file, clientX: 12, clientY: 34 });
});

test("rejects non-right-click, non-image, missing fileId, and missing BinaryFile", () => {
  assert.equal(originalImageRequestForPointer(0, {}, {}, event), null);
  assert.equal(originalImageRequestForPointer(2, { hit: { element: { type: "rectangle" } } }, {}, event), null);
  assert.equal(originalImageRequestForPointer(2, { hit: { element: { type: "image" } } }, {}, event), null);
  assert.equal(originalImageRequestForPointer(2, { hit: { element: { type: "image", fileId: "gone" } } }, {}, event), null);
});

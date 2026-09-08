export function originalImageRequestForPointer(button, pointerDownState, files, event) {
  if (button !== 2) return null;
  const element = pointerDownState?.hit?.element;
  if (element?.type !== "image" || !element.fileId) return null;
  const file = files?.[element.fileId];
  if (!file?.mimeType || !file?.dataURL) return null;
  return {
    fileId: element.fileId,
    mimeType: file.mimeType,
    dataURL: file.dataURL,
    clientX: event.clientX,
    clientY: event.clientY
  };
}

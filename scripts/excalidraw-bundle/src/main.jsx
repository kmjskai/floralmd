import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  MainMenu,
  WelcomeScreen,
  exportToSvg,
  restoreAppState,
  restoreElements,
  serializeAsJSON
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import { originalImageRequestForPointer } from "./image-context.js";
import "./floralmd.css";

const post = (name, value = name) => {
  window.webkit?.messageHandlers?.[name]?.postMessage(value);
};

function FloralMDDrawing() {
  const apiRef = useRef(null);
  const pointerSubscriptionRef = useRef(null);
  const suppressNextImageContextMenuRef = useRef(false);
  const resetPendingRef = useRef(false);
  const readySentRef = useRef(false);
  const [theme, setTheme] = useState(window.__slateMemoTheme || "light");
  const [isEmpty, setIsEmpty] = useState(true);
  const [resetGeneration, setResetGeneration] = useState(0);

  useEffect(() => {
    window.__slateMemoSetTheme = setTheme;
    window.__slateMemoComplete = async ({ includeSVG = true } = {}) => {
      const api = apiRef.current;
      if (!api) return;
      try {
        const elements = api.getSceneElements();
        const appState = api.getAppState();
        const files = api.getFiles();
        const sceneJSON = serializeAsJSON(elements, appState, files, "local");
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>";
        if (includeSVG) {
          const node = await exportToSvg({ elements, appState, files, exportPadding: 16 });
          svg = new XMLSerializer().serializeToString(node);
        }
        post("drawingComplete", JSON.stringify({ sceneJSON, svg, files }));
      } catch (error) {
        post("drawingError", error instanceof Error ? error.message : String(error));
      }
    };
    window.__slateMemoLoadScene = ({ sceneJSON }) => {
      const api = apiRef.current;
      if (!api) throw new Error("Excalidraw 尚未就绪");
      try {
        const scene = JSON.parse(sceneJSON);
        const files = scene.files || {};
        api.addFiles(Object.values(files));
        api.updateScene({
          elements: restoreElements(scene.elements || [], null),
          appState: restoreAppState(scene.appState || {}, api.getAppState())
        });
        setIsEmpty(!(scene.elements || []).some((element) => !element.isDeleted));
        post("drawingLoaded");
      } catch (error) {
        post("drawingError", error instanceof Error ? error.message : String(error));
      }
    };
    window.__slateMemoReset = () => {
      resetPendingRef.current = true;
      apiRef.current = null;
      setResetGeneration((value) => value + 1);
      setIsEmpty(true);
    };
    return () => {
      delete window.__slateMemoSetTheme;
      delete window.__slateMemoComplete;
      delete window.__slateMemoLoadScene;
      delete window.__slateMemoReset;
    };
  }, []);

  useEffect(() => {
    const suppress = (event) => {
      if (!suppressNextImageContextMenuRef.current) return;
      suppressNextImageContextMenuRef.current = false;
      event.preventDefault();
      event.stopImmediatePropagation();
    };
    document.addEventListener("contextmenu", suppress, true);
    return () => document.removeEventListener("contextmenu", suppress, true);
  }, []);

  const attachAPI = useCallback((api) => {
    pointerSubscriptionRef.current?.();
    pointerSubscriptionRef.current = null;
    apiRef.current = api;
    if (!api) return;
    pointerSubscriptionRef.current = api.onPointerDown((_tool, pointerDownState, event) => {
      const request = originalImageRequestForPointer(
        event.button,
        pointerDownState,
        api.getFiles(),
        event
      );
      if (!request) return;
      suppressNextImageContextMenuRef.current = true;
      post("drawingImageContext", JSON.stringify(request));
    });
    if (!readySentRef.current) {
      readySentRef.current = true;
      post("drawingReady");
    }
    if (resetPendingRef.current) {
      resetPendingRef.current = false;
      post("drawingLoaded");
    }
  }, []);

  return (
    <Excalidraw
      excalidrawAPI={attachAPI}
      key={resetGeneration}
      theme={theme}
      langCode="zh-CN"
      onChange={(elements) => setIsEmpty(!elements.some((element) => !element.isDeleted))}
      UIOptions={{
        tools: { image: true },
        canvasActions: {
          changeViewBackgroundColor: true,
          clearCanvas: true,
          export: false,
          loadScene: false,
          saveAsImage: false,
          toggleTheme: false,
          saveToActiveFile: false
        }
      }}
    >
      <MainMenu>
        <MainMenu.Item onSelect={() => post("drawingClose")}>关闭绘图</MainMenu.Item>
        <MainMenu.Item onSelect={() => window.__slateMemoComplete?.()}>完成绘图</MainMenu.Item>
        <MainMenu.Separator />
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.DefaultItems.Help />
      </MainMenu>
      {isEmpty && (
        <WelcomeScreen>
          <WelcomeScreen.Center>
            <WelcomeScreen.Center.Heading>把想法画出来</WelcomeScreen.Center.Heading>
            <WelcomeScreen.Center.Menu>
              <WelcomeScreen.Center.MenuItemHelp />
            </WelcomeScreen.Center.Menu>
          </WelcomeScreen.Center>
          <WelcomeScreen.Hints.MenuHint>从这里关闭或完成绘图</WelcomeScreen.Hints.MenuHint>
          <WelcomeScreen.Hints.ToolbarHint>选择形状、箭头、文字或自由笔迹</WelcomeScreen.Hints.ToolbarHint>
          <WelcomeScreen.Hints.HelpHint>需要时查看绘图快捷键</WelcomeScreen.Hints.HelpHint>
        </WelcomeScreen>
      )}
    </Excalidraw>
  );
}

createRoot(document.getElementById("root")).render(<FloralMDDrawing />);

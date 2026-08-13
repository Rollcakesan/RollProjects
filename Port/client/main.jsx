import { ChakraProvider, defaultSystem } from "@chakra-ui/react";
import { createRoot } from "react-dom/client";
import { App } from "./app.jsx";

const bootstrap = readJson("session-data");
const embeddedProfile = readJson("profile-data");

createRoot(document.querySelector("#root")).render(
  <ChakraProvider value={defaultSystem}>
    <App bootstrap={bootstrap} embeddedProfile={embeddedProfile} />
  </ChakraProvider>,
);

function readJson(id) {
  const element = document.querySelector(`#${id}`);
  if (!element) return null;
  try { return JSON.parse(element.textContent); }
  catch { return null; }
}

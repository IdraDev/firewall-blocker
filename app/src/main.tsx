import ReactDOM from "react-dom/client";
import App from "./App";
import { lang } from "./i18n";
import "./index.css";

document.documentElement.lang = lang;
// no StrictMode: its double-run effects would scan the last folder twice in dev
ReactDOM.createRoot(document.getElementById("root")!).render(<App />);

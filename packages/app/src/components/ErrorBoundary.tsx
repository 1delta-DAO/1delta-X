import { Component, type ErrorInfo, type ReactNode } from "react";

/**
 * The last line of defence against a render-time throw.
 *
 * Without one, React 18 unmounts the whole root and the user sees a blank page
 * with no explanation — which is what a locale-dependent amount parse did to
 * every comma-decimal browser (G-TS_SIGN-6). A crash should say so and offer a
 * way back, not look like a page that never loaded.
 */
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("render failed", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <main style={{ padding: 24 }}>
        <h2>Something went wrong.</h2>
        <p className="dim">{this.state.error.message}</p>
        <button type="button" className="cta" onClick={() => this.setState({ error: null })}>
          Try again
        </button>
      </main>
    );
  }
}

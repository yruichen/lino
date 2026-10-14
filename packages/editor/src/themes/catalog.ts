import definitions from '../../../../assets/themes/classic.json' with { type: 'json' };
import type { EditorPreferences } from '../../../protocol/src/generated/EditorPreferences.ts';
import type { ThemeDefinition } from '../../../protocol/src/generated/ThemeDefinition.ts';

export const builtinThemes: readonly ThemeDefinition[] = definitions;
export function selectedTheme(values?: EditorPreferences): ThemeDefinition {
  return [...builtinThemes, ...(values?.custom_themes ?? [])].find(t => t.id === (values?.theme_family ?? 'paper')) ?? builtinThemes[0];
}
export function bodyFont(values?: EditorPreferences): string {
  return (values?.body_font ? [values.body_font, ...selectedTheme(values).font_families] : selectedTheme(values).font_families).map(name => ['system-ui', 'ui-monospace', 'sans-serif', 'serif', 'monospace', '-apple-system'].includes(name) ? name : JSON.stringify(name)).join(', ');
}
const roles: Record<string, string> = { background: 'bg', panel: 'surface', input: 'bg', button: 'surface', caret: 'accent', active: 'sidebarActive', 'match-selected': 'selection', 'code-background': 'code' };
export function applyThemeTokens(element: HTMLElement, definition: ThemeDefinition, dark: boolean): void {
  const colors = (dark ? definition.dark : definition.light).colors;
  for (const [role, color] of Object.entries(colors)) element.style.setProperty(`--ot-${role}`, color);
  for (const [css, role] of Object.entries(roles)) element.style.setProperty(`--ot-${css}`, colors[role]);
  element.style.setProperty('--ot-reading-width', `${definition.reading_width}px`);
}

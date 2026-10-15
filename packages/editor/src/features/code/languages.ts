import { languages } from '@codemirror/language-data';
import { type Language, LanguageDescription, StreamLanguage } from '@codemirror/language';
import { javascript } from '@codemirror/lang-javascript';
import { python } from '@codemirror/lang-python';
import { rust } from '@codemirror/lang-rust';
import { cpp } from '@codemirror/lang-cpp';
import { java } from '@codemirror/lang-java';
import { json } from '@codemirror/lang-json';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { sql } from '@codemirror/lang-sql';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { yaml } from '@codemirror/legacy-modes/mode/yaml';
import { go } from '@codemirror/legacy-modes/mode/go';

// One catalogue drives both the picker and Markdown's nested code parser.
// An unknown identifier stays in the file and renders as plain text.
export const codeLanguages = [
  { id: 'javascript', name: 'JavaScript', aliases: ['js', 'jsx'], create: () => javascript({ jsx: true }).language },
  { id: 'typescript', name: 'TypeScript', aliases: ['ts', 'tsx'], create: () => javascript({ typescript: true, jsx: true }).language },
  { id: 'python', name: 'Python', aliases: ['py'], create: () => python().language },
  { id: 'rust', name: 'Rust', aliases: ['rs'], create: () => rust().language },
  { id: 'cpp', name: 'C / C++', aliases: ['c', 'c++', 'h', 'hpp'], create: () => cpp().language },
  { id: 'java', name: 'Java', aliases: [], create: () => java().language },
  { id: 'json', name: 'JSON', aliases: [], create: () => json().language },
  { id: 'html', name: 'HTML', aliases: ['htm'], create: () => html().language },
  { id: 'css', name: 'CSS', aliases: [], create: () => css().language },
  { id: 'sql', name: 'SQL', aliases: [], create: () => sql().language },
  { id: 'shell', name: 'Shell', aliases: ['sh', 'bash', 'zsh'], create: () => StreamLanguage.define(shell) },
  { id: 'yaml', name: 'YAML', aliases: ['yml'], create: () => StreamLanguage.define(yaml) },
  { id: 'go', name: 'Go', aliases: ['golang'], create: () => StreamLanguage.define(go) },
];
const cache = new Map<string, Language>();
export const isPlainCode = (name: string): boolean => !name || ['text', 'txt', 'plain', 'plaintext', 'none'].includes(name.toLowerCase());
export function languageForCode(info: string): Language | null {
  const name = info.trim().split(/\s+/, 1)[0].toLowerCase();
  const entry = codeLanguages.find(item => item.id === name || item.aliases.includes(name));
  if (!entry) return extraLanguage(info)?.support?.language ?? null;
  if (!cache.has(entry.id)) cache.set(entry.id, entry.create());
  return cache.get(entry.id)!;
}

function extraLanguage(info: string): LanguageDescription | null {
  return LanguageDescription.matchLanguageName(languages, info.trim().split(/\s+/, 1)[0], false);
}
export function codeLanguageForMarkdown(info: string): Language | LanguageDescription | null {
  return languageForCode(info) ?? extraLanguage(info);
}
export async function loadCodeLanguage(info: string): Promise<Language | null> {
  const existing = languageForCode(info); if (existing) return existing;
  return (await extraLanguage(info)?.load())?.language ?? null;
}
export const codeLanguageChoices = [
  { id: 'text', name: 'Plain text', aliases: ['txt', 'plaintext'] },
  ...codeLanguages,
  ...languages.filter(language => !codeLanguages.some(existing => existing.id === language.name.toLowerCase() || language.alias.includes(existing.id)))
    .map(language => ({ id: language.alias[0] ?? language.name.toLowerCase(), name: language.name, aliases: language.alias })),
  { id: 'mermaid', name: 'Mermaid', aliases: [] },
];

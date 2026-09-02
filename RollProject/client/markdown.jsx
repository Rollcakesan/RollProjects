import React from "react";

export function Markdown({ children }) {
  const lines = String(children || "").replace(/\r\n?/gu, "\n").split("\n");
  const nodes = [];
  let code = null;
  let list = [];
  const flushList = () => { if (list.length) { nodes.push(<ul key={`list-${nodes.length}`}>{list.map((line, index) => <li key={index}>{inline(line)}</li>)}</ul>); list = []; } };
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.startsWith("```")) {
      flushList();
      if (code === null) code = [];
      else { nodes.push(<pre key={`code-${index}`}><code>{code.join("\n")}</code></pre>); code = null; }
      continue;
    }
    if (code !== null) { code.push(line); continue; }
    const listMatch = line.match(/^[-*] (.+)$/u);
    if (listMatch) { list.push(listMatch[1]); continue; }
    flushList();
    if (!line) { nodes.push(<div className="md-space" key={`space-${index}`} />); continue; }
    const heading = line.match(/^(#{1,3})\s+(.+)$/u);
    if (heading) { const Tag = `h${heading[1].length + 1}`; nodes.push(<Tag key={index}>{inline(heading[2])}</Tag>); continue; }
    if (line.startsWith("> ")) { nodes.push(<blockquote key={index}>{inline(line.slice(2))}</blockquote>); continue; }
    nodes.push(<p key={index}>{inline(line)}</p>);
  }
  flushList();
  if (code !== null) nodes.push(<pre key="code-last"><code>{code.join("\n")}</code></pre>);
  return <div className="markdown">{nodes}</div>;
}

function inline(text) {
  const pattern = /(\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)|`([^`]+)`|\*\*([^*]+)\*\*)/gu;
  const output = []; let cursor = 0; let match;
  while ((match = pattern.exec(text))) {
    if (match.index > cursor) output.push(text.slice(cursor, match.index));
    if (match[2]) output.push(<a key={match.index} href={match[3]} target="_blank" rel="noreferrer">{match[2]}</a>);
    else if (match[4]) output.push(<code key={match.index}>{match[4]}</code>);
    else output.push(<strong key={match.index}>{match[5]}</strong>);
    cursor = pattern.lastIndex;
  }
  if (cursor < text.length) output.push(text.slice(cursor));
  return output;
}

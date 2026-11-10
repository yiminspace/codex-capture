import MarkdownIt from 'markdown-it';

const markdown = new MarkdownIt({ html: false, breaks: true });
markdown.validateLink = url => /^https?:\/\//i.test(url);
markdown.renderer.rules.link_open = (tokens, index, options, _env, renderer) => {
  tokens[index].attrSet('target', '_blank');
  tokens[index].attrSet('rel', 'noopener noreferrer');
  return renderer.renderToken(tokens, index, options);
};
// Keep alt text without fetching resources from model output.
markdown.renderer.rules.image = (tokens, index, options, env, renderer) =>
  markdown.utils.escapeHtml(renderer.renderInlineAsText(tokens[index].children ?? [], options, env));

export function MarkdownResult({ text }: { text: string }) {
  return <div className="result-text" dangerouslySetInnerHTML={{ __html: markdown.render(text) }} />;
}

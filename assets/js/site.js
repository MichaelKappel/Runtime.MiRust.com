(() => {
  const groups = [...document.querySelectorAll('.menu-group')];
  document.addEventListener('click', event => {
    for (const group of groups) {
      if (!group.contains(event.target)) group.removeAttribute('open');
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') groups.forEach(group => group.removeAttribute('open'));
  });
  document.querySelectorAll('.menu-panel a').forEach(link => {
    link.addEventListener('click', () => groups.forEach(group => group.removeAttribute('open')));
  });
  document.querySelectorAll('[data-copy]').forEach(button => {
    button.addEventListener('click', async () => {
      const value = button.getAttribute('data-copy') || location.href;
      try {
        await navigator.clipboard.writeText(value);
        button.textContent = 'Copied';
        setTimeout(() => { button.textContent = button.getAttribute('data-label') || 'Copy'; }, 1400);
      } catch {
        button.textContent = 'Copy failed';
        setTimeout(() => { button.textContent = button.getAttribute('data-label') || 'Copy'; }, 1400);
      }
    });
  });
})();

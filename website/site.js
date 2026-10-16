const copy = document.querySelector('#copy-brew');
copy?.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#brew-command').textContent);
    status.textContent = copy.dataset.copy;
  } catch { status.textContent = copy.dataset.failed; }
});

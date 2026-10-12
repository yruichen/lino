// Filter the report locally; no analytics or network requests.
document.querySelector('#query').addEventListener('input',event=>{
  const query=event.target.value.toLowerCase().trim();
  document.querySelectorAll('article tbody tr').forEach(row=>{
    row.classList.toggle('hidden',Boolean(query)&&!row.textContent.toLowerCase().includes(query));
  });
});

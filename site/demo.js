// Interactive app-card demo: a native recreation of the OpenShokz window.
// A scripted cursor adds a video (paste → download → transfer) and deletes
// one via the row context menu, on a loop. Plus 3D hover parallax.

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

const card = document.getElementById('appCard')
const stage = card.closest('.card-stage')
const rowList = document.getElementById('rowList')
const addBar = document.getElementById('addBar')
const addBtn = document.getElementById('addBtn')
const addText = document.getElementById('addText')
const sendBtn = document.getElementById('sendBtn')
const ctxMenu = document.getElementById('ctxMenu')
const ctxDelete = document.getElementById('ctxDelete')
const cursor = document.getElementById('demoCursor')

const LIBRARY = [
  {
    title: 'Acquired: Costco',
    duration: '3:01:34',
    thumb: 'assets/thumbs/acquired.jpg',
  },
  {
    title: 'Joe Rogan Experience #1169 - Elon Musk',
    duration: '2:37:02',
    thumb: 'assets/thumbs/ycPr5-27vSI.jpg',
  },
  {
    title: 'Master Your Sleep & Be More Alert When Awake',
    duration: '34:00',
    thumb: 'assets/thumbs/lIo9FcrljDk.jpg',
  },
  {
    title: 'Sam Altman: OpenAI CEO on GPT-4, ChatGPT, and the Future of AI',
    duration: '2:23:56',
    thumb: 'assets/thumbs/L_Guz73e6fw.jpg',
  },
]

const ADDED = {
  title: 'Why the Cease-Fire With Iran Keeps Crumbling',
  duration: '31:05',
  thumb: 'assets/thumbs/X-3Y0Y68Wg4.jpg',
  url: 'youtube.com/watch?v=X-3Y0Y68Wg4',
}

function rowElement({ title, duration, thumb }) {
  const li = document.createElement('li')
  const img = document.createElement('img')
  img.className = 'thumb'
  img.src = thumb
  img.alt = ''
  const span = document.createElement('span')
  span.className = 'row-title'
  span.textContent = title
  const dur = document.createElement('span')
  dur.className = 'row-dur'
  dur.textContent = duration
  li.append(img, span, dur)
  return li
}

function renderLibrary() {
  rowList.replaceChildren(...LIBRARY.map(rowElement))
}

renderLibrary()

/* ------------------------------------------------ 3D hover parallax */

if (!reducedMotion) {
  stage.addEventListener('mousemove', (event) => {
    const rect = stage.getBoundingClientRect()
    const nx = (event.clientX - rect.left) / rect.width - 0.5
    const ny = (event.clientY - rect.top) / rect.height - 0.5
    card.style.transform =
      `scale(1.05) translate(${nx * 8}px, ${ny * 8}px) ` +
      `rotateY(${nx * 10}deg) rotateX(${-ny * 10}deg)`
    card.style.setProperty('--sheen-x', `${(nx + 0.5) * 100}%`)
    card.style.setProperty('--sheen-y', `${(ny + 0.5) * 100}%`)
  })
  stage.addEventListener('mouseleave', () => {
    card.style.transform = ''
    card.style.removeProperty('--sheen-x')
    card.style.removeProperty('--sheen-y')
  })

  // Same parallax tilt on the connect-guide card.
  const howto = document.querySelector('.howto')
  if (howto) {
    howto.addEventListener('mousemove', (event) => {
      // Over the podcast-link popover: keep the card flat so the tooltip,
      // which lives inside the card, isn't 3D-warped by the tilt.
      if (event.target.closest('.tip-anchor')) {
        howto.style.transform = ''
        return
      }
      const rect = howto.getBoundingClientRect()
      const nx = (event.clientX - rect.left) / rect.width - 0.5
      const ny = (event.clientY - rect.top) / rect.height - 0.5
      // Identical parameters to the demo card so both cards feel the same.
      howto.style.transform =
        `scale(1.05) translate(${nx * 8}px, ${ny * 8}px) ` +
        `rotateY(${nx * 10}deg) rotateX(${-ny * 10}deg)`
    })
    howto.addEventListener('mouseleave', () => {
      howto.style.transform = ''
    })
  }
}

/* Click a glass card → a quick pop-out pulse, then settle. Applies to both
   the live demo card and the connect-guide card. */
function attachPop(el) {
  if (!el) return
  el.addEventListener('pointerdown', () => {
    if (reducedMotion) return
    el.classList.remove('pop')
    // Reflow so the animation restarts on rapid repeat clicks.
    void el.offsetWidth
    el.classList.add('pop')
  })
  el.addEventListener('animationend', (event) => {
    if (event.animationName === 'cardPop') el.classList.remove('pop')
  })
}
attachPop(card)
attachPop(document.querySelector('.howto'))

/* ------------------------------------------------------ demo scripting */

const sleep = (ms) =>
  new Promise((resolve) => setTimeout(resolve, ms))

async function waitVisible() {
  while (document.hidden) {
    await sleep(500)
  }
}

/** Element center in the card's untransformed coordinate space. */
function centerOf(el) {
  let x = el.offsetWidth / 2
  let y = el.offsetHeight / 2
  let node = el
  while (node && node !== card) {
    x += node.offsetLeft
    y += node.offsetTop
    node = node.offsetParent
  }
  return { x, y }
}

function moveCursor(x, y, ms = 700) {
  cursor.style.transitionDuration = `${ms}ms`
  // Hotspot: the glyph's top-left tip (8.5, 6.5 in a 28-unit viewBox at 26px).
  cursor.style.transform = `translate(${x - 8}px, ${y - 6}px)`
  return sleep(ms + 60)
}

const moveCursorTo = (el, ms) => {
  const { x, y } = centerOf(el)
  return moveCursor(x, y, ms)
}

async function click(el) {
  cursor.classList.add('clicking')
  el?.classList?.add('hovered')
  await sleep(140)
  cursor.classList.remove('clicking')
  el?.classList?.remove('hovered')
  await sleep(120)
}

async function typeText(target, text) {
  for (const char of text) {
    target.textContent += char
    await sleep(22)
  }
}

function downloadRow() {
  const li = document.createElement('li')
  li.classList.add('entering', 'downloading')
  const img = document.createElement('img')
  img.className = 'thumb'
  img.src = ADDED.thumb
  img.alt = ''
  const box = document.createElement('div')
  box.className = 'row-progress'
  const span = document.createElement('span')
  span.className = 'row-title'
  span.textContent = ADDED.title
  const track = document.createElement('div')
  track.className = 'progress-track'
  const fill = document.createElement('div')
  fill.className = 'progress-fill'
  track.append(fill)
  const status = document.createElement('span')
  status.className = 'row-status'
  status.textContent = 'Downloading…'
  box.append(span, track, status)
  li.append(img, box)
  return { li, fill, status }
}

async function addFlow() {
  await moveCursorTo(addBtn, 750)
  await click(addBtn)
  addBar.classList.add('open')
  await sleep(420)

  await typeText(addText, ADDED.url)
  await sleep(350)

  await moveCursorTo(sendBtn, 450)
  await click(sendBtn)
  addBar.classList.remove('open')
  addText.textContent = ''

  const { li, fill, status } = downloadRow()
  rowList.prepend(li)
  await sleep(400)
  for (const pct of [12, 31, 47, 66, 82, 100]) {
    fill.style.width = `${pct}%`
    await sleep(340)
  }
  status.textContent = 'Copying to headphones…'
  await sleep(1000)

  // Freshly added tracks stay at the top of the list.
  const done = rowElement(ADDED)
  li.replaceWith(done)
  return done
}

async function deleteFlow(row) {
  if (!row || !row.isConnected) return
  await moveCursorTo(row, 700)
  row.classList.add('hovered')
  await sleep(250)

  const { x, y } = centerOf(row)
  ctxMenu.style.left = `${Math.min(x, 130)}px`
  ctxMenu.style.top = `${y + 8}px`
  ctxMenu.classList.add('open')
  await sleep(650)

  await moveCursorTo(ctxDelete, 480)
  ctxDelete.classList.add('hovered')
  await sleep(260)
  await click(ctxDelete)
  ctxDelete.classList.remove('hovered')
  ctxMenu.classList.remove('open')
  row.classList.remove('hovered')

  row.classList.add('removing')
  await sleep(380)
  row.remove()
}

async function demoLoop() {
  await sleep(1500)
  for (;;) {
    await waitVisible()
    const added = await addFlow()
    await sleep(1700)
    await waitVisible()
    await deleteFlow(added)
    await sleep(2400)
  }
}

if (!reducedMotion) {
  demoLoop()
}

/* ------------------------------------------------------ brew copy */

const brew = document.getElementById('brewCmd')
brew?.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(brew.querySelector('code').textContent)
    brew.classList.add('copied')
    setTimeout(() => brew.classList.remove('copied'), 1600)
  } catch {
    // Clipboard unavailable (permissions); selection fallback not worth it here.
  }
})

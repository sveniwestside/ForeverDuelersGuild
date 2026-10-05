import { readView, viewUrl, profileRecords, opponentMix, orientPair, matchupProposal, selectedBandEstimate } from './ladder-view.mjs';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const number = new Intl.NumberFormat('en-GB');
const dateTime = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const shortDate = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short' });
const analysisDate = new Intl.DateTimeFormat('en-GB', { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'UTC', timeZoneName: 'short' });
const preview = new URLSearchParams(location.search).get('preview') === '1';
const classes = {
  WARRIOR: { name: 'Warrior' }, PALADIN: { name: 'Paladin' }, HUNTER: { name: 'Hunter' },
  ROGUE: { name: 'Rogue' }, PRIEST: { name: 'Priest' }, SHAMAN: { name: 'Shaman' },
  MAGE: { name: 'Mage' }, WARLOCK: { name: 'Warlock' }, DRUID: { name: 'Druid' },
};
const state = readView(location.search);
let design;
let listController;
let profileController;
let importController;
let comparisonController;
let comparisonData;
let searchTimer;

function element(tag, className, content) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content !== undefined && content !== null) node.textContent = String(content);
  return node;
}
function svg(path, className = '') {
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  node.setAttribute('viewBox', '0 0 24 24');
  node.setAttribute('aria-hidden', 'true');
  if (className) node.setAttribute('class', className);
  const line = document.createElementNS(node.namespaceURI, 'path');
  line.setAttribute('d', path);
  node.append(line);
  return node;
}
function avatar(classFile) {
  const node = element('span', 'class-avatar');
  if (!Object.hasOwn(classes, classFile)) {
    node.textContent = '?';
    node.setAttribute('aria-label', 'Unknown class');
    return node;
  }
  const image = element('img');
  image.src = `/assets/classes/${classFile.toLowerCase()}.png`;
  image.alt = classes[classFile].name;
  image.width = 56;
  image.height = 56;
  node.append(image);
  return node;
}
function dateValue(value) {
  if (value === null || value === undefined || value === '') return new Date(NaN);
  return new Date(typeof value === 'number' && Math.abs(value) < 1e12 ? value * 1000 : value);
}
function formatDate(value, formatter = dateTime) {
  const date = dateValue(value);
  return Number.isFinite(date.getTime()) ? formatter.format(date) : 'No duels yet';
}
function rate(player) {
  const wins = Number(player.wins);
  const losses = Number(player.losses);
  const fraction = Number.isFinite(wins) && Number.isFinite(losses) && wins + losses > 0 ? wins / (wins + losses) : 0;
  return Math.max(0, Math.min(1, fraction || 0));
}
async function api(path, options = {}) {
  const response = await fetch(`/api/v1/${path}`, { ...options, headers: { Accept: 'application/json', ...(options.headers || {}) } });
  let data;
  try { data = await response.json(); } catch { throw new Error('The server returned an invalid response.'); }
  if (!response.ok) {
    const message = typeof data.error === 'string' ? data.error : data.error?.message || data.message;
    throw new Error(message || `The request could not be completed (${response.status}).`);
  }
  return data;
}
function query(extra = {}) {
  return new URLSearchParams({ ...state, ...extra }).toString();
}
function writeView(replace = false) {
  const url = viewUrl(location.href, state);
  if (url !== location.href) history[replace ? 'replaceState' : 'pushState']({}, '', url);
}
function syncView() {
  $('#player-search').value = state.search;
  if (![...$('#level-cap').options].some(option => Number(option.value) === state.maxLevel)) {
    const option = element('option', '', state.maxLevel);
    option.value = String(state.maxLevel);
    $('#level-cap').append(option);
  }
  $('#level-cap').value = String(state.maxLevel);
  $$('[data-bracket]').forEach(tab => {
    const selected = tab.dataset.bracket === state.bracket;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  $$('[data-class-selector]').forEach(tab => {
    const selected = tab.dataset.classSelector === state.classFile;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  const classTab = state.classFile ? `class-${state.classFile.toLowerCase()}` : 'class-overall';
  $('#ladder-tabpanel').setAttribute('aria-labelledby', `${state.bracket === 'MAX_LEVEL' ? 'tab-max' : 'tab-leveling'} ${classTab}`);
  $('#ranking-title').textContent = state.classFile ? `${classes[state.classFile].name} ladder` : 'Overall ladder';
  $('#duels-title').textContent = state.classFile ? `${classes[state.classFile].name} duels` : 'Duel log';
}
function previewList(kind) {
  return kind === 'ladder' ? design.ladder(state) : design.recentMatches({ ...state, page: 1, limit: 4 });
}
function playerButton(player, showRealm = true) {
  const button = element('button', 'player-profile');
  button.type = 'button';
  button.setAttribute('aria-label', `Open ${player.name}'s profile`);
  button.addEventListener('click', () => openProfile(player.guid));
  button.append(avatar(player.classFile));
  const labels = element('span');
  labels.append(element('span', 'player-name', player.name));
  if (showRealm) {
    const realm = element('div', 'player-realm');
    realm.append(element('span', 'class-name', classes[player.classFile]?.name || player.classFile), element('span', 'realm-separator', '·'), element('span', 'realm-name', player.realm));
    labels.append(realm);
  }
  button.append(labels);
  return button;
}
function loadingLadder() {
  $('#ladder-status').hidden = true;
  $('#ladder-body').replaceChildren();
  $('#ladder-body').setAttribute('aria-busy', 'true');
  for (let i = 0; i < 6; i++) {
    const row = element('tr', 'skeleton-row');
    row.setAttribute('aria-hidden', 'true');
    ['rank-cell', '', 'level-cell', 'rating-cell', 'record-cell', 'winrate-cell', 'detail-cell'].forEach(className => {
      const cell = element('td', className);
      cell.append(element('span', 'skeleton'));
      row.append(cell);
    });
    $('#ladder-body').append(row);
  }
  $('#ranking-total').textContent = 'Loading ladder…';
  $('#previous-page').disabled = true;
  $('#next-page').disabled = true;
}
function showLadderStatus(title, description, retry = false) {
  $('#ladder-body').replaceChildren();
  const status = $('#ladder-status');
  status.replaceChildren(element('strong', '', title), element('p', '', description));
  if (retry) {
    const button = element('button', '', 'Try again');
    button.type = 'button';
    button.addEventListener('click', refresh);
    status.append(button);
  }
  status.hidden = false;
}
function renderLadder(data) {
  $('#ladder-body').replaceChildren();
  const total = Number(data.total) || 0;
  const page = Number(data.page) || state.page;
  const limit = Number(data.limit) || state.limit;
  const items = Array.isArray(data.items) ? data.items : [];
  const classView = state.ranking === 'CLASS';
  const weighted = classView && data.model?.status === 'available' && state.bracket === 'MAX_LEVEL';
  $('#rank-column-label').textContent = classView ? 'Class #' : '#';
  $('#rating-column-label').textContent = weighted ? 'Class Rating' : 'Overall Elo';
  $('#ranking-footnote').textContent = weighted
    ? data.model.source === 'manual' ? 'Class Rating uses the published manual matchup baseline. It is a hypothesis, not a measured class win rate. Overall Elo is unchanged.'
      : 'Class Rating uses the published matchup baseline, supported by provisional leveling evidence. This does not establish max-level class balance. Overall Elo is unchanged.'
    : classView ? 'These are ranks within this class, ordered by Overall Elo. Matchup-adjusted Class Rating is not applied to this pool.'
      : 'Overall Elo is unchanged. Select a class for its own ladder; each mode and level cap has a separate pool.';
  $('#ladder-status').hidden = true;
  for (const player of items) {
    const row = element('tr');
    const rankCell = element('td', 'rank-cell');
    const rank = classView ? player.classRank ?? player.rank : player.overallRank ?? player.rank;
    rankCell.append(element('span', `rank-number rank-${rank}`, rank));
    const nameCell = element('td');
    nameCell.append(playerButton(player));
    const levelCell = element('td', 'level-cell');
    levelCell.append(element('span', 'level-value', player.level));
    const ratingCell = element('td', 'rating-cell');
    const value = weighted ? player.classRating : player.rating;
    const rating = element('span', 'rating-value', Number.isFinite(value) ? number.format(value) : '—');
    if (!weighted) rating.append(element('small', '', 'ELO'));
    ratingCell.append(rating);
    if (weighted) ratingCell.append(element('span', 'rating-secondary', `Overall ${number.format(player.rating)}`));
    const recordCell = element('td', 'record-cell');
    const record = element('span', 'record-value');
    record.append(element('span', 'record-wins', number.format(player.wins)), element('span', 'record-divider', '/'), element('span', 'record-losses', number.format(player.losses)));
    recordCell.append(record);
    const winrateCell = element('td', 'winrate-cell');
    const winrate = element('div', 'winrate-content');
    const bar = element('span', 'winrate-bar');
    const fill = element('span');
    fill.style.width = `${rate(player) * 100}%`;
    bar.append(fill);
    winrate.append(element('span', 'winrate-value', `${Math.round(rate(player) * 100)}%`), bar);
    winrateCell.append(winrate);
    const arrowCell = element('td', 'detail-cell');
    arrowCell.append(svg('m9 5 7 7-7 7', 'detail-arrow'));
    row.append(rankCell, nameCell, levelCell, ratingCell, recordCell, winrateCell, arrowCell);
    $('#ladder-body').append(row);
  }
  if (!items.length) {
    showLadderStatus(state.search ? 'No matching duelists.' : 'No confirmed duels yet.', state.search ? 'Try a different search in this ladder.' : 'The ladder starts with the first results confirmed by both players.');
  }
  $('#ranking-total').textContent = `${number.format(total)} ${total === 1 ? 'duelist' : 'duelists'}`;
  $('#ranking-range').textContent = items.length ? `${number.format((page - 1) * limit + 1)}–${number.format(Math.min(page * limit, total))} of ${number.format(total)} ${total === 1 ? 'duelist' : 'duelists'}` : 'No rankings yet';
  $('#page-label').textContent = `Page ${number.format(page)} of ${number.format(Math.max(1, Math.ceil(total / limit)))}`;
  $('#previous-page').disabled = page <= 1;
  $('#next-page').disabled = page * limit >= total;
}
function renderMatches(data) {
  const list = $('#matches-list');
  list.replaceChildren();
  if (!data.items?.length) {
    const empty = element('div', 'matches-empty');
    empty.append(element('strong', '', 'No entries yet.'), element('p', '', 'The latest confirmed duels in this ladder will appear here.'));
    list.append(empty);
    return;
  }
  for (const match of data.items.slice(0, 4)) {
    const card = element('article', 'match-card');
    const top = element('div', 'match-top');
    top.append(element('span', 'match-bracket', `${match.bracket === 'MAX_LEVEL' ? 'MAX LEVEL' : 'LEVELING'} · ${match.maxLevel}`), element('time', 'match-time', formatDate(match.endedAt)));
    top.lastChild.dateTime = dateValue(match.endedAt).toISOString();
    const duel = element('div', 'match-duel');
    for (const [index, player] of [match.winner, match.loser].entries()) {
      if (index) duel.append(element('span', 'match-versus', 'vs'));
      const side = element('div', 'match-player');
      const button = playerButton(player, false);
      button.className = '';
      button.querySelector('.player-name').className = 'match-player-name';
      const rating = element('div', 'match-rating', number.format(player.ratingAfter));
      rating.append(element('span', `match-delta ${index ? 'negative' : 'positive'}`, `${player.delta > 0 ? '+' : ''}${player.delta}`));
      side.append(button, rating);
      duel.append(side);
    }
    const bottom = element('div', 'match-bottom');
    const confirmed = element('span', 'match-confirmed');
    confirmed.append(svg('m5 12 4 4L19 6'), document.createTextNode('Confirmed by both players'));
    bottom.append(confirmed, element('span', 'match-winner', `Winner: ${match.winner.name}`));
    card.append(top, duel, bottom);
    list.append(card);
  }
}
async function refresh() {
  listController?.abort();
  listController = new AbortController();
  const controller = listController;
  loadingLadder();
  $('#matches-list').replaceChildren(element('div', 'matches-empty', 'Loading recent duels…'));
  const results = await Promise.allSettled([
    preview ? Promise.resolve(previewList('ladder')) : api(`ladder?${query()}`, { signal: controller.signal }),
    preview ? Promise.resolve(previewList('matches')) : api(`matches?${query({ page: 1, limit: 4 })}`, { signal: controller.signal }),
  ]);
  if (controller.signal.aborted) return;
  $('#ladder-body').setAttribute('aria-busy', 'false');
  if (results[0].status === 'fulfilled') renderLadder(results[0].value);
  else {
    showLadderStatus('The ladder is currently unavailable.', results[0].reason.message, true);
    $('#ranking-total').textContent = 'Connection lost';
    $('#ranking-range').textContent = 'No data available';
  }
  if (results[1].status === 'fulfilled') renderMatches(results[1].value);
  else {
    const empty = element('div', 'matches-empty');
    empty.append(element('strong', '', 'Recent duels could not be loaded.'), element('p', '', results[1].reason.message));
    const retry = element('button', 'error-retry', 'Try again');
    retry.type = 'button';
    retry.addEventListener('click', refresh);
    empty.append(retry);
    $('#matches-list').replaceChildren(empty);
  }
}
function graph(series, initialRating) {
  const points = series.filter(point => Number.isFinite(Number(point.rating)) && Number.isFinite(dateValue(point.endedAt).getTime()));
  if (!points.length) return element('p', 'no-history', 'Your rating history begins with your first confirmed duel.');
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  node.setAttribute('viewBox', '0 0 560 185');
  node.setAttribute('class', 'profile-chart');
  node.setAttribute('role', 'img');
  node.setAttribute('aria-label', `Rating history across ${number.format(points.length)} ${points.length === 1 ? 'duel' : 'duels'}. Starting rating ${number.format(points[0].rating)}, current rating ${number.format(points.at(-1).rating)}.`);
  const values = points.map(point => Number(point.rating));
  const low = Math.floor((Math.min(...values, initialRating) - 10) / 50) * 50;
  const high = Math.ceil((Math.max(...values, initialRating) + 10) / 50) * 50;
  const left = 42, right = 548, top = 14, bottom = 154;
  const x = i => left + i * (right - left) / Math.max(1, points.length - 1);
  const y = value => bottom - (value - low) / (high - low) * (bottom - top);
  const part = (tag, attributes) => {
    const child = document.createElementNS(node.namespaceURI, tag);
    for (const [key, value] of Object.entries(attributes)) child.setAttribute(key, String(value));
    node.append(child);
    return child;
  };
  for (let i = 0; i < 3; i++) {
    const value = low + i * (high - low) / 2;
    part('path', { d: `M${left} ${y(value)}H${right}`, class: 'chart-grid' });
    part('text', { x: 0, y: y(value) + 3, class: 'chart-label' }).textContent = number.format(value);
  }
  const coordinates = points.map((point, i) => `${x(i)} ${y(Number(point.rating))}`).join('L');
  if (points.length > 1) part('path', { d: `M${coordinates}L${right} ${bottom}L${left} ${bottom}Z`, fill: 'var(--chart-area, #739959)', 'fill-opacity': '.07', stroke: 'none' });
  part('path', { d: `M${coordinates}`, class: 'chart-line' });
  part('circle', { cx: x(points.length - 1), cy: y(values.at(-1)), r: 3.5, fill: 'var(--chart-dot, #608e42)', stroke: 'var(--chart-dot-stroke, #fcfbf7)', 'stroke-width': 2 });
  part('text', { x: left, y: 180, class: 'chart-label' }).textContent = formatDate(points[0].endedAt, shortDate);
  part('text', { x: right, y: 180, class: 'chart-label', 'text-anchor': 'end' }).textContent = formatDate(points.at(-1).endedAt, shortDate);
  return node;
}
const mediaHosts = new Set(['render.worldofwarcraft.com', 'render-eu.worldofwarcraft.com', 'render-us.worldofwarcraft.com', 'render-kr.worldofwarcraft.com', 'render-tw.worldofwarcraft.com']);
function officialUrl(value, kind) {
  if (typeof value !== 'string' || value.length > 1024) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash) return null;
    if (kind === 'armory') {
      if (url.hostname !== 'worldofwarcraft.blizzard.com' || !/^\/[a-z]{2}-[a-z]{2}\/character\/(eu|us|kr|tw)\/[^/]+\/[^/]+\/?$/i.test(url.pathname)) return null;
    } else if (!mediaHosts.has(url.hostname) || !/\.(?:png|jpe?g|webp)$/i.test(url.pathname)) return null;
    return url.href;
  } catch { return null; }
}
function characterSection(character) {
  const section = element('section', 'character-section');
  const heading = element('div', 'character-heading');
  heading.append(element('h3', '', 'Blizzard profile'), element('span', 'character-source', 'CHARACTER DATA'));
  section.append(heading);
  if (preview) {
    section.append(element('p', 'character-preview', 'Example character. Blizzard profile data is not fetched in this preview.'));
    return section;
  }
  const game = character?.game;
  const summary = character?.summary;
  const available = character?.status === 'available' && character.source === 'blizzard' && summary &&
    ['retail', 'classic', 'classic-era'].includes(game) && summary.game === game && character.linkedGame === game;
  if (!available) {
    let message = 'Blizzard character data is currently unavailable for this duelist.';
    if (character?.status === 'unsupported') message = character.reason === 'forever_not_documented'
      ? 'Blizzard Profile API support for WoW Forever has not yet been verified.'
      : 'No matching Blizzard character data is available for this game mode.';
    else if (character?.status === 'not_configured') message = 'Blizzard character data has not been enabled on this instance yet.';
    else if (character?.reason === 'unmapped') message = 'No matching Blizzard profile has been linked to this duelist yet.';
    section.append(element('p', 'character-unavailable', message));
    return section;
  }
  const gameName = { retail: 'Retail', classic: 'Classic', 'classic-era': 'Classic Era' }[game];
  section.append(element('p', 'character-summaryline', `${summary.name} · ${summary.realm} · ${gameName}`));
  const faction = String(summary.faction || '').toLowerCase();
  if (faction === 'horde') section.dataset.faction = 'horde';
  else if (['alliance', 'allianz'].includes(faction)) section.dataset.faction = 'alliance';
  const profile = element('div', 'character-profile');
  const portraitUrl = officialUrl(character.media?.avatar, 'media');
  if (portraitUrl) {
    const portrait = element('img', 'character-avatar');
    portrait.src = portraitUrl;
    portrait.alt = `Blizzard portrait of ${summary.name}`;
    portrait.width = 78;
    portrait.height = 78;
    portrait.loading = 'lazy';
    portrait.referrerPolicy = 'no-referrer';
    portrait.addEventListener('error', () => portrait.remove(), { once: true });
    profile.append(portrait);
  }
  const facts = element('dl', 'character-facts');
  for (const [label, value] of [['Race', summary.race], ['Class', summary.class], ['Faction', summary.faction], ['Level', summary.level], ['Guild', summary.guild], ['Specialization', summary.spec], ['Item level', summary.itemLevel], ['Region', summary.region?.toUpperCase()]]) {
    if ((typeof value !== 'string' && typeof value !== 'number') || value === '' || (typeof value === 'number' && !Number.isFinite(value))) continue;
    const fact = element('div');
    fact.append(element('dt', '', label), element('dd', '', value));
    facts.append(fact);
  }
  profile.append(facts);
  section.append(profile);
  const armoryUrl = game === 'retail' ? officialUrl(character.armoryUrl, 'armory') : null;
  if (armoryUrl) {
    const link = element('a', 'character-link', 'View in the official Armory');
    link.href = armoryUrl;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.append(element('span', '', '↗'));
    section.append(link);
  }
  section.append(element('p', 'character-provenance', `Source: Blizzard Profile API${character.updatedAt ? ` · Retrieved ${formatDate(character.updatedAt)}` : ''}. Character data enriches this profile and does not confirm duel results.`));
  return section;
}
async function openProfile(guid) {
  const dialog = $('#profile-dialog');
  profileController?.abort();
  profileController = new AbortController();
  const controller = profileController;
  const content = $('#profile-content');
  const loading = element('div', 'profile-state');
  const heading = element('h2', '', 'Loading profile…');
  heading.id = 'profile-title';
  loading.append(heading);
  content.replaceChildren(loading);
  if (!dialog.open) dialog.showModal();
  try {
    const pool = new URLSearchParams({ bracket: state.bracket, maxLevel: state.maxLevel });
    const data = preview ? design.profile(guid) : await api(`players/${encodeURIComponent(guid)}?${pool}`, { signal: controller.signal });
    if (controller.signal.aborted) return;
    renderProfile(data, state.ranking === 'CLASS' && Number.isFinite(data.player.classRating) ? 'CLASS' : 'OVERALL');
  } catch (error) {
    if (controller.signal.aborted) return;
    const failure = element('div', 'profile-state');
    const title = element('h2', '', 'This profile is currently unavailable.');
    title.id = 'profile-title';
    failure.append(title, element('p', '', error.message));
    const retry = element('button', 'error-retry', 'Try again');
    retry.type = 'button';
    retry.addEventListener('click', () => openProfile(guid));
    failure.append(retry);
    content.replaceChildren(failure);
  }
}
function renderProfile(data, selectedMetric) {
  const player = data.player;
  const classMetric = selectedMetric === 'CLASS' && Number.isFinite(player.classRating);
  const header = element('div', 'profile-header');
  const name = element('h2', '', player.name);
  name.id = 'profile-title';
  const labels = element('div');
  labels.append(name, element('p', 'profile-subtitle', `${classes[player.classFile]?.name || player.classFile} · ${player.realm} · Level ${player.level}`),
    element('p', 'profile-record-line', `${number.format(player.wins)} W / ${number.format(player.losses)} L · ${Math.round(rate(player) * 100)}% win rate`));
  header.append(avatar(player.classFile), labels);
  const metrics = element('div', `profile-stats${Number.isFinite(player.classRating) ? ' profile-stats-four' : ''}`);
  const values = [['Overall Elo', number.format(player.rating)]];
  if (Number.isFinite(player.classRating)) values.push(['Class Rating', number.format(player.classRating)]);
  values.push([`${classes[player.classFile]?.name || 'Class'} rank`, player.classRank ? `#${number.format(player.classRank)}` : '—'], ['Overall rank', player.overallRank || player.rank ? `#${number.format(player.overallRank || player.rank)}` : '—']);
  for (const [label, value] of values) {
    const metric = element('div', 'profile-stat');
    metric.append(element('strong', '', value), element('span', '', label));
    metrics.append(metric);
  }
  const metricTabs = element('div', 'profile-metric-tabs');
  metricTabs.setAttribute('role', 'group');
  metricTabs.setAttribute('aria-label', 'Rating history metric');
  for (const [key, label] of [['OVERALL', 'Overall Elo'], ['CLASS', 'Class Rating']]) {
    if (key === 'CLASS' && !Number.isFinite(player.classRating)) continue;
    const button = element('button', `profile-metric-tab${(classMetric ? 'CLASS' : 'OVERALL') === key ? ' active' : ''}`, label);
    button.type = 'button';
    button.setAttribute('aria-pressed', String((classMetric ? 'CLASS' : 'OVERALL') === key));
    button.addEventListener('click', () => renderProfile(data, key));
    metricTabs.append(button);
  }
  const chartHeading = element('div', 'profile-chart-heading', `${classMetric ? 'Class Rating' : 'Overall Elo'} history`);
  chartHeading.append(element('span', '', `${player.bracket === 'LEVELING' ? 'Leveling' : 'Max level'} · Level cap ${player.maxLevel}`));
  const ratingNote = element('p', 'profile-mix-note', Number.isFinite(player.classRating)
    ? 'Class Rating accounts for published matchup assumptions and is compared within this class ladder. Overall Elo remains separate.'
    : 'This class ladder uses Overall Elo. Matchup-adjusted Class Rating is unavailable in this pool.');
  const records = profileRecords(data, classMetric ? 'CLASS' : 'OVERALL');
  const history = element('div', 'profile-history');
  for (const match of records.history.slice(0, 5)) {
    const won = String(match.result).toUpperCase() === 'WIN';
    const row = element('div', 'profile-history-row');
    row.append(element('span', `history-result${won ? '' : ' loss'}`, won ? 'Win' : 'Loss'), element('span', 'history-opponent', `vs. ${match.opponent?.name || 'Unknown'}`), element('span', 'history-date', formatDate(match.endedAt, shortDate)), element('span', 'history-delta', `${match.delta > 0 ? '+' : ''}${match.delta}`));
    history.append(row);
  }
  if (!history.children.length) history.append(element('p', 'no-history', `No confirmed duels are available for this ${classMetric ? 'Class Rating' : 'Overall Elo'} history.`));
  const mix = element('section', 'opponent-mix');
  mix.append(element('h3', 'profile-history-title', 'Opponents by class'));
  const groups = opponentMix(data.history);
  for (const group of groups) {
    const row = element('div', 'opponent-mix-row');
    const identity = element('span', 'opponent-mix-class');
    identity.append(avatar(group.classFile), document.createTextNode(classes[group.classFile].name));
    row.append(identity, element('span', '', `${number.format(group.wins)} W / ${number.format(group.losses)} L`), element('span', 'opponent-mix-count', `${number.format(group.distinctOpponents)} ${group.distinctOpponents === 1 ? 'opponent' : 'opponents'}`));
    mix.append(row);
  }
  if (!groups.length) mix.append(element('p', 'no-history', 'No opponent-class history is available for this pool.'));
  else mix.append(element('p', 'profile-mix-note', 'Observed results from this confirmed history. Small samples are not estimates of class balance.'));
  $('#profile-content').replaceChildren(header, metrics, metricTabs, ratingNote, chartHeading, graph(records.series, 1500),
    element('h3', 'profile-history-title', `Recent duels · ${classMetric ? 'Class Rating' : 'Overall Elo'} changes`), history, mix, characterSection(data.character));
}
function changeBracket(bracket) {
  state.bracket = bracket;
  state.page = 1;
  clearTimeout(searchTimer);
  syncView();
  writeView();
  refresh();
}
$$('[data-bracket]').forEach(tab => {
  tab.addEventListener('click', () => changeBracket(tab.dataset.bracket));
  tab.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const target = event.key === 'Home' ? $('#tab-max') : event.key === 'End' ? $('#tab-leveling') : tab.id === 'tab-max' ? $('#tab-leveling') : $('#tab-max');
    changeBracket(target.dataset.bracket);
    target.focus();
  });
});
$$('[data-class-selector]').forEach(tab => {
  tab.addEventListener('click', () => changeClass(tab.dataset.classSelector));
  tab.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const tabs = $$('[data-class-selector]');
    const index = tabs.indexOf(tab);
    const target = event.key === 'Home' ? tabs[0] : event.key === 'End' ? tabs.at(-1) : tabs[(index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
    changeClass(target.dataset.classSelector);
    target.focus();
    target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  });
});
function changeClass(classFile) {
  state.classFile = classFile;
  state.ranking = classFile ? 'CLASS' : 'OVERALL';
  state.page = 1;
  clearTimeout(searchTimer);
  syncView();
  writeView();
  refresh();
  if (classFile) { $('#comparison-class').value = classFile; renderComparison(); }
}
const bandNames = { 'max-level': 'Max level' };
function initializeComparisons() {
  for (const id of ['comparison-class', 'comparison-opponent']) {
    for (const [value, info] of Object.entries(classes)) {
      const option = element('option', '', info.name);
      option.value = value;
      $( `#${id}` ).append(option);
    }
  }
  $('#comparison-class').value = state.classFile || 'MAGE';
  $('#comparison-opponent').value = $('#comparison-class').value === 'WARRIOR' ? 'MAGE' : 'WARRIOR';
  $('#comparison-class').addEventListener('change', renderComparison);
  $('#comparison-opponent').addEventListener('change', renderComparison);
  $('#comparison-band').addEventListener('change', renderComparison);
}
async function loadComparisons() {
  comparisonController?.abort();
  comparisonController = new AbortController();
  const controller = comparisonController;
  comparisonData = undefined;
  $('#comparison-content').replaceChildren(element('p', 'comparison-state', 'Loading matchup data…'));
  $('#comparison-band').disabled = true;
  try {
    const data = preview ? design.comparisons(state.maxLevel) : await api(`class-comparisons?${new URLSearchParams({ maxLevel: state.maxLevel })}`, { signal: controller.signal });
    if (controller.signal.aborted) return;
    comparisonData = data;
    const oldBand = $('#comparison-band').value;
    $('#comparison-band').replaceChildren();
    for (const band of data.bands || []) {
      const option = element('option', '', bandNames[band.id] ? `Max level (${band.maxLevel})` : `Levels ${band.minLevel}–${band.maxLevel}`);
      option.value = band.id;
      $('#comparison-band').append(option);
    }
    $('#comparison-band').value = data.bands?.some(band => band.id === oldBand) ? oldBand : data.bands?.some(band => band.id === 'levels-50-59') ? 'levels-50-59' : data.bands?.[0]?.id || '';
    $('#comparison-band').disabled = !data.bands?.length;
    renderComparison();
  } catch (error) {
    if (controller.signal.aborted) return;
    const failure = element('div', 'comparison-state');
    failure.append(element('strong', '', 'Matchup data is currently unavailable.'), element('p', '', error.message));
    const retry = element('button', 'error-retry', 'Try again');
    retry.type = 'button';
    retry.addEventListener('click', loadComparisons);
    failure.append(retry);
    $('#comparison-content').replaceChildren(failure);
  }
}
function probabilityLabel(value) {
  return Number.isFinite(value) ? `${Math.round(value * 100)}%` : '—';
}
function intervalLabel(interval) {
  return Array.isArray(interval) && interval.length === 2 && interval.every(Number.isFinite)
    ? `95% CI ${number.format(Math.round(interval[0] * 1000) / 10)}–${number.format(Math.round(interval[1] * 1000) / 10)}%` : '95% CI unavailable';
}
function evidenceReason(reason) {
  const messages = {
    previous_window_insufficient_data: 'The previous high-level window has insufficient independent evidence.',
    latest_window_insufficient_data: 'The latest high-level window has insufficient independent evidence.',
    previous_window_fit_failed: 'The previous high-level model did not converge.',
    latest_window_fit_failed: 'The latest high-level model did not converge.',
    previous_window_bootstrap_incomplete: 'Uncertainty validation is incomplete for the previous window.',
    latest_window_bootstrap_incomplete: 'Uncertainty validation is incomplete for the latest window.',
    previous_window_interval_contains_baseline: 'The previous window does not exclude the baseline.',
    latest_window_interval_contains_baseline: 'The latest window does not exclude the baseline.',
    window_directions_disagree: 'The two high-level windows point in different directions.',
    pooled_estimate_unavailable: 'A combined high-level estimate is unavailable.',
    pooled_direction_disagrees: 'The combined estimate disagrees with the window signal.',
    fresh_validation_required: 'New independent validation windows are required.',
    max_level_uncertainty_unresolved: 'Available max-level counterevidence has unresolved uncertainty.',
    max_level_contradiction: 'Available max-level evidence contradicts the leveling signal.',
    no_change: 'The validated estimate proposes no change to the baseline.',
    model_changed: 'The published model changed after this analysis. New validation is required.',
  };
  return messages[reason] || 'This proposal has not satisfied an evidence check.';
}
function estimateCell(pair) {
  const cell = element('td');
  cell.append(document.createTextNode(probabilityLabel(pair?.estimatedProbability)));
  const interval = element('span', 'comparison-ci', intervalLabel(pair?.ci95));
  cell.append(interval);
  return cell;
}
function renderComparison() {
  const selectedClass = $('#comparison-class').value;
  const opponentSelect = $('#comparison-opponent');
  for (const option of opponentSelect.options) option.disabled = option.value === selectedClass;
  if (opponentSelect.value === selectedClass) opponentSelect.value = Object.keys(classes).find(classFile => classFile !== selectedClass);
  if (!comparisonData) return;
  const opponentClass = opponentSelect.value;
  const band = comparisonData.bands?.find(value => value.id === $('#comparison-band').value);
  const pair = orientPair(band?.pairs?.find(value => value.classA === selectedClass && value.classB === opponentClass || value.classA === opponentClass && value.classB === selectedClass), selectedClass);
  const targetName = classes[selectedClass].name;
  const opponentName = classes[opponentClass].name;
  const baseline = element('article', 'comparison-baseline');
  const manualProbability = comparisonData.manualBaseline?.probabilities?.[selectedClass]?.[opponentClass]
    ?? (comparisonData.model?.source === 'manual' ? pair?.baselineProbability : null);
  baseline.append(element('h3', '', 'Manual baseline'));
  baseline.append(element('strong', 'comparison-value', probabilityLabel(manualProbability)));
  baseline.append(element('p', '', `${targetName} win probability at equal skill.`));
  baseline.append(element('p', 'comparison-detail', Number.isFinite(manualProbability)
    ? 'The initial published hypothesis, not an observed win rate.' : 'No supported manual baseline is available for this level cap.'));
  if (comparisonData.model?.source === 'leveling-supported') {
    baseline.append(element('p', 'comparison-current-baseline', `Current published baseline: ${probabilityLabel(pair?.baselineProbability)} · Leveling evidence — provisional.`),
      element('p', 'comparison-detail', 'Manually approved for the active rating model. This does not establish max-level class balance.'));
  }
  const bandEstimate = selectedBandEstimate(comparisonData, band?.id, selectedClass, opponentClass);
  const bandModel = element('article', 'comparison-band-model');
  bandModel.append(element('h3', '', 'Selected band · model estimate'), element('strong', 'comparison-value', probabilityLabel(bandEstimate?.estimatedProbability)));
  bandModel.append(element('span', 'comparison-ci', intervalLabel(bandEstimate?.ci95)), element('p', '', `${targetName} probability after modeled player skill.`));
  bandModel.append(element('p', 'comparison-detail', Number.isFinite(bandEstimate?.estimatedProbability)
    ? `${number.format(bandEstimate.rawMatches || 0)} equal-level duels · ${number.format(Math.round(bandEstimate.weightedMatches || 0))} weighted duels. Descriptive band evidence; not an eligible model change.`
    : 'Insufficient data for a band estimate. No probability is inferred from the observed win rate.'));
  const proposal = matchupProposal(comparisonData, selectedClass, opponentClass);
  const evidence = element('article', 'comparison-evidence');
  evidence.append(element('h3', '', proposal.status === 'historical' ? 'Historical evidence — new validation required' : proposal.status === 'provisional' ? 'Leveling evidence — provisional' : proposal.status === 'blocked' ? 'No eligible proposal' : 'Insufficient data'));
  evidence.append(element('strong', 'comparison-value', probabilityLabel(proposal.status === 'historical' ? proposal.archivedProbability : proposal.probability)));
  evidence.append(element('p', '', proposal.status === 'historical' ? 'Archived proposal; not currently eligible.' : proposal.status === 'provisional' ? `Proposed ${targetName} win probability.` : 'No eligible leveling-supported adjustment.'));
  evidence.append(element('p', 'comparison-detail', proposal.status === 'provisional'
    ? 'Supported by the validated high-level windows. This proposal has not automatically changed the published rating model.'
    : proposal.status === 'historical' ? 'The analysis used an earlier baseline. Its estimates remain visible as historical evidence.'
    : proposal.status === 'blocked' ? 'The available counterevidence blocks this proposal.'
      : 'The required evidence checks are not satisfied. Raw band results alone do not qualify.'));
  if (proposal.reasons.length) {
    const reasons = element('ul', 'comparison-reasons');
    [...new Set(proposal.reasons.map(evidenceReason))].forEach(message => reasons.append(element('li', '', message)));
    evidence.append(reasons);
  }
  const columns = element('div', 'comparison-estimates');
  columns.append(baseline, bandModel, evidence);
  const diagnostic = element('div', 'comparison-diagnostic');
  const bandLabel = band ? band.id === 'max-level' ? `Max level ${band.maxLevel}` : `Levels ${band.minLevel}–${band.maxLevel}` : 'Selected level band';
  const diagnosticTitle = element('h3', '', `${bandLabel} · observed results`);
  diagnostic.append(diagnosticTitle);
  if (pair) {
    const identities = element('div', 'comparison-identities');
    identities.append(avatar(selectedClass), element('span', '', `${targetName} ${number.format(pair.winsA || 0)} W / ${number.format(pair.winsB || 0)} L`), avatar(opponentClass), element('span', '', opponentName));
    diagnostic.append(identities, element('p', 'comparison-sample', `${number.format(pair.rawMatches || 0)} confirmed duels · ${number.format(pair.sameLevelMatches || 0)} equal-level duels · ${number.format(pair.uniqueA || 0)} ${targetName} players · ${number.format(pair.uniqueB || 0)} ${opponentName} players · ${number.format(pair.uniquePairs || 0)} unique pairs`));
  } else diagnostic.append(element('p', '', 'No qualifying records are available in this band.'));
  diagnostic.append(element('p', 'comparison-detail', 'Observed results include unequal-level duels within this band. Only equal-level records enter the calibration sample. Neither count establishes equal-skill class balance.'));
  const overview = element('div', 'comparison-overview');
  const overallPair = orientPair(comparisonData.overview?.pairs?.find(value => value.classA === selectedClass && value.classB === opponentClass || value.classA === opponentClass && value.classB === selectedClass), selectedClass);
  overview.append(element('span', '', `${targetName} vs. ${opponentName}, all levels: ${number.format(overallPair?.rawMatches || 0)} confirmed duels · ${number.format(overallPair?.winsA || 0)} W / ${number.format(overallPair?.winsB || 0)} L`),
    element('span', '', `All class pairs: ${number.format(comparisonData.counts?.confirmedMatches || 0)} duels, including ${number.format(comparisonData.counts?.crossBandMatches || 0)} across level bands and ${number.format(comparisonData.counts?.sameClassMatches || 0)} same-class duels.`));
  const validation = element('div', 'comparison-validation');
  validation.append(element('h3', '', 'High-level validation & max-level counterevidence'));
  if (proposal.candidate) {
    const scroll = element('div', 'comparison-table-scroll');
    const table = element('table');
    const caption = element('caption', 'sr-only', `Modeled ${targetName} win probability against ${opponentName}, with equal-level calibration samples.`);
    const header = element('thead');
    const headerRow = element('tr');
    for (const label of ['Evidence sample', `${targetName} estimate`, 'Weighted duels', 'Players / pairs', 'Fit / uncertainty']) headerRow.append(element('th', '', label));
    for (const cell of headerRow.children) cell.scope = 'col';
    header.append(headerRow);
    const body = element('tbody');
    const samples = [...(proposal.candidate.windows || []).map(window => ({ ...window, label: window.windowId === 'previous-14d' ? 'Levels 50–59 · previous 14 days' : window.windowId === 'latest-14d' ? 'Levels 50–59 · latest 14 days' : 'Levels 50–59 · validation window' })),
      { ...proposal.candidate.maxLevel, label: 'Max level · recent 28 days' }];
    for (const sample of samples) {
      const oriented = orientPair(sample.classA ? sample : { ...sample, classA: proposal.candidate.classA, classB: proposal.candidate.classB }, selectedClass);
      const row = element('tr');
      const fitLabel = oriented?.fitSucceeded === false ? 'Fit failed' : !Number.isFinite(oriented?.estimatedProbability) ? 'Insufficient data' : `${oriented.bootstrapSuccessful || 0} / ${oriented.bootstrapReplicates || 0} bootstrap fits`;
      row.append(element('td', '', sample.label), estimateCell(oriented), element('td', '', number.format(Math.round(oriented?.weightedMatches || 0))),
        element('td', '', `${number.format(oriented?.uniqueA || 0)} / ${number.format(oriented?.uniqueB || 0)} players · ${number.format(oriented?.uniquePairs || 0)} pairs`), element('td', '', fitLabel));
      body.append(row);
    }
    table.append(caption, header, body);
    scroll.append(table);
    validation.append(scroll);
  } else validation.append(element('p', 'comparison-detail', 'No window analysis is available for this pair. Missing max-level data alone does not reject a leveling proposal.'));
  validation.append(element('p', 'comparison-detail', 'Only a validated candidate can support a provisional adjustment. Small samples, repeated opponents and confidence intervals that include the baseline do not qualify.'));
  const model = comparisonData.model;
  const analysis = comparisonData.analysis;
  const metadata = element('p', 'comparison-metadata', `Manual baseline: ${comparisonData.manualBaseline?.id || 'unavailable'}. Published model: ${model?.id || 'unavailable'}${model?.source ? ` · ${model.source}` : ''}${model?.effectiveFrom ? ` · effective ${formatDate(model.effectiveFrom, analysisDate)}` : ''}.`);
  if (analysis) metadata.append(element('span', '', ` Analysis ${analysis.analysisId || ''} · baseline ${analysis.activeModelId || 'not supplied'} · data cutoff ${formatDate(analysis.dataCutoff, analysisDate)} · generated ${formatDate(analysis.generatedAt, analysisDate)}.`));
  else metadata.append(document.createTextNode(' No calibration analysis has been published.'));
  const nodes = [columns, diagnostic, overview, validation, metadata];
  if (proposal.status === 'historical') nodes.unshift(element('p', 'comparison-historical', 'Historical evidence — new validation required. These estimates predate the published model.'));
  $('#comparison-content').replaceChildren(...nodes);
}
$('#level-cap').addEventListener('change', event => {
  state.maxLevel = Number(event.target.value); state.page = 1; clearTimeout(searchTimer); syncView(); writeView(); refresh(); loadComparisons();
});
$('#player-search').addEventListener('input', event => {
  clearTimeout(searchTimer);
  state.search = event.target.value.trim();
  state.page = 1;
  searchTimer = setTimeout(() => { writeView(true); refresh(); }, 220);
});
$('#previous-page').addEventListener('click', () => { state.page = Math.max(1, state.page - 1); clearTimeout(searchTimer); writeView(); refresh(); });
$('#next-page').addEventListener('click', () => { state.page += 1; clearTimeout(searchTimer); writeView(); refresh(); });
window.addEventListener('popstate', () => {
  clearTimeout(searchTimer);
  const oldCap = state.maxLevel;
  Object.assign(state, readView(location.search));
  if ($('#profile-dialog').open) $('#profile-dialog').close();
  syncView(); refresh();
  if (state.classFile) { $('#comparison-class').value = state.classFile; renderComparison(); }
  if (oldCap !== state.maxLevel) loadComparisons();
});
document.addEventListener('keydown', event => {
  if (event.key === '/' && !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName) && !$$('dialog').some(dialog => dialog.open)) {
    event.preventDefault();
    $('#player-search').focus();
  }
});
$$('[data-open-import]').forEach(button => button.addEventListener('click', () => $('#import-dialog').showModal()));
$$('[data-close-dialog]').forEach(button => button.addEventListener('click', () => button.closest('dialog').close()));
$$('dialog').forEach(dialog => dialog.addEventListener('click', event => {
  if (event.target !== dialog) return;
  const bounds = dialog.getBoundingClientRect();
  if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
}));
$('#profile-dialog').addEventListener('close', () => profileController?.abort());
$('#import-dialog').addEventListener('close', () => {
  importController?.abort();
  $('#import-token').value = '';
  $('#import-form').reset();
  $('#file-label').textContent = 'Choose a JSON file';
  $('#import-status').hidden = true;
});
$('#import-file').addEventListener('change', event => { $('#file-label').textContent = event.target.files[0]?.name || 'Choose a JSON file'; });
$('#import-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (preview) return;
  const status = $('#import-status');
  const button = $('#import-submit');
  const file = $('#import-file').files[0];
  if (!file) return;
  importController?.abort();
  importController = new AbortController();
  const controller = importController;
  status.className = 'import-status';
  status.hidden = false;
  status.textContent = 'Checking your match history…';
  button.disabled = true;
  try {
    if (file.size > 2 * 1024 * 1024) throw new Error('Your match history file must be no larger than 2 MB.');
    let data;
    try { data = JSON.parse(await file.text()); } catch { throw new Error('Choose a valid JSON file created by the export tool.'); }
    if (data?.schemaVersion !== 2 || !data?.player?.guid || !Array.isArray(data?.matches)) throw new Error('This match history file has an unsupported format. Export your current add-on history using schema 2.');
    const token = $('#import-token').value.trim();
    if (!token) throw new Error('Enter your personal upload key.');
    const headers = { Authorization: `Bearer ${token}` };
    const identity = await api('me', { headers, signal: controller.signal });
    if (identity.guid !== data.player.guid) throw new Error('This upload key belongs to a different character than the match history file.');
    const result = await api('import', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify(data), signal: controller.signal });
    if (controller.signal.aborted) return;
    const counts = { pending: 0, confirmed: 0, disputed: 0 };
    for (const item of result.results || []) if (item.status in counts) counts[item.status] += 1;
    status.replaceChildren(element('strong', '', 'Your match history has been received.'), element('p', '', `${number.format(result.accepted || 0)} imported · ${number.format(result.duplicates || 0)} already uploaded`), element('p', '', `${number.format(counts.confirmed)} confirmed · ${number.format(counts.pending)} awaiting the other player's upload · ${number.format(counts.disputed)} disputed`));
    $('#import-token').value = '';
    refresh();
    await loadMeta();
  } catch (error) {
    if (controller.signal.aborted) return;
    status.classList.add('error');
    status.textContent = error.message;
  } finally {
    button.disabled = preview;
  }
});
async function loadMeta() {
  const results = await Promise.allSettled([preview ? Promise.resolve(design.config) : api('config'), preview ? Promise.resolve(design.stats) : api('stats')]);
  if (results[0].status === 'fulfilled') {
    const config = results[0].value;
    $('#demo-banner').hidden = preview || !config.demo;
    $('#initial-rating').textContent = number.format(config.initialRating || 1500);
    $$('[data-addon-version]').forEach(node => { node.textContent = config.addonVersion || node.textContent; });
  }
  if (results[1].status === 'fulfilled') {
    const stats = results[1].value;
    $('#stat-players').textContent = number.format(stats.players || 0);
    $('#stat-matches').textContent = number.format(stats.confirmedMatches || 0);
    $('#stat-updated').textContent = stats.lastUpdated ? formatDate(stats.lastUpdated) : 'No duels yet';
  } else $('#stat-updated').textContent = 'Currently unavailable';
}
async function init() {
  $('#preview-banner').hidden = !preview;
  $('#import-preview-notice').hidden = !preview;
  if (preview) {
    design = await import('./assets/design-preview.js');
    $$('#import-form input, #import-submit').forEach(input => { input.disabled = true; });
  }
  syncView();
  initializeComparisons();
  await Promise.allSettled([loadMeta(), refresh(), loadComparisons()]);
}
init().catch(error => {
  showLadderStatus('The preview could not be loaded.', error.message, true);
  $('#matches-list').replaceChildren(element('div', 'matches-empty', 'Please reload the page.'));
});

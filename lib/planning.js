/* Planning Le Treuil : lecture du fichier Excel et calcul des dates (jours ouvrés).
   Reproduit les formules du classeur : durée = ARRONDI.SUP(Qté × J.O./unité / MAX(1;Équipes)),
   début = WORKDAY selon le lien (FD, DD, FF) et le décalage, fin = WORKDAY(début ; durée − 1). */
(function (root) {
  const DAY = 86400000;
  const toNum = d => Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / DAY);
  const excelToNum = v => (typeof v === 'number' ? Math.round(v) - 25569 : (v instanceof Date ? toNum(new Date(v.getTime() + 12 * 3600000)) : null));
  const isoToNum = s => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || ''); return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) / DAY : null; };
  const numToIso = n => new Date(n * DAY).toISOString().slice(0, 10);
  const weekday = n => new Date(n * DAY).getUTCDay();
  const txt = v => (v == null ? '' : String(v).trim());
  const nrm = v => txt(v).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ');

  /* ---------- Lecture du classeur (SheetJS) ---------- */
  function parseWorkbook(XLSX, wb) {
    const sheet = name => { const k = wb.SheetNames.find(n => nrm(n) === nrm(name)); return k ? XLSX.utils.sheet_to_json(wb.Sheets[k], { header: 1, raw: true, defval: null }) : null; };
    const P = sheet('Planning'); if (!P) throw new Error('onglet « Planning » introuvable');
    const hi = P.findIndex(r => r && nrm(r[0]) === 'n°' && nrm(r[1]) === 'tache'); if (hi < 0) throw new Error('en-tête « N° / Tâche » introuvable');
    const tasks = []; let phase = null, phaseName = '';
    for (const r of P.slice(hi + 1)) {
      if (!r) continue; const a = txt(r[0]);
      if (/^P[0-9V]+$/i.test(a)) { phase = a.toUpperCase(); phaseName = txt(r[1]); continue; }
      if (!/^\d+$/.test(a)) continue;
      const num = v => (v === null || v === '' || isNaN(+v) ? null : +v);
      tasks.push({ n: +a, label: txt(r[1]), ent: txt(r[2]), tour: txt(r[3]), qte: num(r[4]), jo: num(r[5]), eq: num(r[6]),
        imp: excelToNum(r[8]), pred: num(r[9]), lien: txt(r[10]).toUpperCase() || 'FD', dec: num(r[11]) || 0, avct: num(r[14]), phase, phaseName });
    }
    const feries = []; const ents = [];
    const S = sheet('Paramètres') || sheet('Parametres');
    if (S) { const h = S.findIndex(r => r && nrm(r[0]) === 'code');
      for (const r of S.slice(h + 1)) { if (!r) continue; if (txt(r[0])) ents.push({ code: txt(r[0]), nom: txt(r[1]) });
        const d = excelToNum(r[4]); if (d) feries.push({ d: numToIso(d), label: txt(r[5]) || 'Jour férié' }); } }
    const tpl = [];
    const L = sheet('Planning logement');
    if (L) { const h = L.findIndex(r => r && nrm(r[0]) === 'phase');
      for (const r of L.slice(h + 1)) { if (!r || !/^\d+$/.test(txt(r[0]))) { if (r && txt(r[0]) && !/^\d+$/.test(txt(r[0]))) break; continue; }
        tpl.push({ phase: 'P' + txt(r[0]), label: txt(r[1]), ent: txt(r[2]), dur: +r[3] || 1, par: +r[4] || 1, lien: txt(r[5]).toUpperCase() || '', dec: +r[6] || 0 }); } }
    const start = excelToNum((P[4] || [])[12]);
    return { tasks, feries, ents, tpl, start: start ? numToIso(start) : null, imported: new Date().toISOString() };
  }

  /* ---------- Calendrier de jours ouvrés ---------- */
  function makeCal(offSet) {
    const from = isoToNum('2025-01-01'), to = isoToNum('2030-12-31'); const days = [], idx = new Map();
    for (let n = from; n <= to; n++) { const w = weekday(n); if (w === 0 || w === 6 || offSet.has(n)) continue; idx.set(n, days.length); days.push(n); }
    const at = n => { if (idx.has(n)) return idx.get(n); let lo = 0, hi = days.length; while (lo < hi) { const m = (lo + hi) >> 1; days[m] < n ? lo = m + 1 : hi = m; } return lo; };
    return {
      // WORKDAY(start ; k) d'Excel : k jours ouvrés après (ou avant) start, start exclu
      workday(start, k) { if (k === 0) return start; if (k > 0) { let i = idx.has(start) ? idx.get(start) : at(start) - 1; return days[i + k]; } let i = at(start); return days[i + k]; },
      idx: at, day: i => days[i], isWork: n => idx.has(n)
    };
  }

  /* ---------- Calcul ---------- */
  function compute(model, offs) {
    const baseOff = new Set(), entOff = {};
    for (const f of model.feries || []) { const n = isoToNum(f.d); if (n != null) baseOff.add(n); }
    for (const o of offs || []) { const a = isoToNum(o.d), b = isoToNum(o.f || o.d); if (a == null) continue;
      for (let n = a; n <= Math.max(a, b == null ? a : b); n++) { if (o.ent) (entOff[o.ent] = entOff[o.ent] || new Set()).add(n); else baseOff.add(n); } }
    const cals = {}; const calFor = ent => { const k = ent && entOff[ent] ? ent : ''; if (!cals[k]) cals[k] = makeCal(k ? new Set([...baseOff, ...entOff[k]]) : baseOff); return cals[k]; };
    const byN = new Map(model.tasks.map(t => [t.n, t])); const res = new Map(); const busy = new Set();
    const dur = t => (t.qte > 0 && t.jo > 0 ? Math.ceil(t.qte * t.jo / Math.max(1, t.eq || 1) - 1e-9) : 1);
    function calc(t) {
      if (res.has(t.n)) return res.get(t.n); if (busy.has(t.n)) return null; busy.add(t.n);
      const C = calFor(t.ent), H = dur(t); let s = null; const p = t.pred != null ? byN.get(t.pred) : null; const pr = p ? calc(p) : null;
      if (t.pred == null || !pr) { if (t.imp != null) s = C.workday(t.imp - 1, 1); }
      else if (t.lien === 'DD') s = C.workday(pr.s - 1, 1 + t.dec);
      else if (t.lien === 'FF') s = Math.max(C.workday(C.workday(pr.e, t.dec), -(H - 1)), C.workday(pr.s, 1));
      else s = C.workday(pr.e, 1 + t.dec);
      const r = s == null ? null : { s, e: C.workday(s, H - 1), h: H }; res.set(t.n, r); busy.delete(t.n); return r;
    }
    model.tasks.forEach(calc);
    return { res, calFor, dur };
  }

  /* Dates par logement pour une phase et une tour.
     ids : logements dans l'ordre de passage. Cadence = J.O./unité ÷ MAX(1 ; équipes) de la 1re tâche de la phase. */
  function logements(model, comp, phase, tour, ids) {
    const ts = model.tasks.filter(t => t.phase === phase && t.tour === tour); if (!ts.length) return null;
    const main = ts[0], r = comp.res.get(main.n); if (!r) return null;
    const C = comp.calFor(main.ent), cad = (main.jo || 1) / Math.max(1, main.eq || 1);
    const steps = (model.tpl || []).filter(x => x.phase === phase); let prev = null; const st = [];
    for (const x of steps) { const o = prev && x.lien === 'DD' ? prev.o + x.dec : prev && x.lien === 'FD' ? prev.o + prev.dur + x.dec : 0; st.push({ ...x, o }); prev = { o, dur: x.dur }; }
    if (!st.length) st.push({ label: main.label, ent: main.ent, dur: cad, o: 0 });
    const tot = Math.max(...st.map(x => x.o + x.dur));
    const base = C.idx(r.s) * 2; // demi-journées
    const half = h => ({ d: numToIso(C.day(Math.floor(h / 2))), pm: h % 2 === 1 });
    const out = ids.map((id, k) => { const h0 = base + Math.round(k * cad * 2);
      return { id, k, s: half(h0), e: half(h0 + Math.max(1, Math.round(tot * 2)) - 1),
        steps: st.map(x => ({ label: x.label, ent: x.ent, s: half(h0 + Math.round(x.o * 2)), e: half(h0 + Math.round((x.o + x.dur) * 2) - 1) })) }; });
    return { main, tower: { s: numToIso(Math.min(...ts.map(t => (comp.res.get(t.n) || r).s))), e: numToIso(Math.max(...ts.map(t => (comp.res.get(t.n) || r).e))) }, qte: main.qte, cad, list: out };
  }

  root.TreuilPlanning = { parseWorkbook, compute, logements, isoToNum, numToIso };
})(typeof window !== 'undefined' ? window : globalThis);

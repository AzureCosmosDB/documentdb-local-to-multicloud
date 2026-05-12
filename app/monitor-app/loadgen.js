/**
 * Load generator for the multi-cloud DocumentDB Techorama demo.
 *
 * Drives a realistic travel-booking-site operation mix against the current
 * primary's Mongo gateway:
 *
 *   80%  browse  — find with filter+sort+limit on `bookingsdb.listings`  (read)
 *   15%  detail  — findOne by _id on `bookingsdb.listings`                (read)
 *    4%  insert  — single insertOne on `bookingsdb.loadgen_bookings`      (write)
 *    1%  update  — updateOne by _id on a recent loadgen booking           (write)
 *
 * Hits a SEPARATE collection (`loadgen_bookings`) so the demo Bookings tab
 * (which targets `bookings`) stays clean and one-at-a-time replication is
 * still visually clear.
 *
 * Exposes start/stop/stats/config endpoints. Tracks per-op latency, error
 * counts, and rolling RPS.
 */

const { ObjectId } = require("mongodb");

const DEFAULT_MIX = { browse: 80, detail: 15, insert: 4, update: 1 };
const MAX_RPS = 500;
const MAX_IN_FLIGHT = 20;
const STATS_WINDOW_SEC = 60;
const RECENT_INSERT_RING_SIZE = 200;
const LISTINGS_SAMPLE_SIZE = 500;

const CITIES = [
  "Antwerp", "Brussels", "Ghent", "Bruges", "Leuven",
  "Amsterdam", "Rotterdam", "Paris", "Berlin", "Munich",
];

function pickWeighted(mix) {
  const total = mix.browse + mix.detail + mix.insert + mix.update;
  let r = Math.random() * total;
  if ((r -= mix.browse) < 0) return "browse";
  if ((r -= mix.detail) < 0) return "detail";
  if ((r -= mix.insert) < 0) return "insert";
  return "update";
}

function pickRandom(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

function randomDateBetween(daysAhead, spanDays) {
  const start = Date.now() + daysAhead * 86400_000;
  return new Date(start + Math.random() * spanDays * 86400_000);
}

function emptyOpStats() {
  return { count: 0, errors: 0, latency_ms_total: 0, latency_p95_window: [] };
}

function quantile(sorted, q) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * q));
  return sorted[idx];
}

class LoadGen {
  constructor({ getDbForPrimary, log }) {
    this.getDbForPrimary = getDbForPrimary;
    this.log = log || (() => {});
    this.running = false;
    this.rps = 0;
    this.mix = { ...DEFAULT_MIX };
    this.listingsSample = [];
    this.listingsSampleAt = 0;
    this.recentInsertIds = [];
    this.tickHandle = null;
    this.startedAt = 0;
    this.opStats = {
      browse: emptyOpStats(),
      detail: emptyOpStats(),
      insert: emptyOpStats(),
      update: emptyOpStats(),
    };
    this.recentOpsTimes = [];   // unix ms timestamps for RPS calc
    this.recentLatencies = [];  // {op, ms, ts}
    this.inFlight = 0;
    this.dropped = 0;
  }

  status() {
    const now = Date.now();
    const windowStart = now - STATS_WINDOW_SEC * 1000;
    const recentOps = this.recentOpsTimes.filter((t) => t >= windowStart);
    const recentLat = this.recentLatencies.filter((x) => x.ts >= windowStart);
    const observedRps = recentOps.length / Math.min(STATS_WINDOW_SEC, Math.max(1, (now - this.startedAt) / 1000));
    const allLat = recentLat.map((x) => x.ms).sort((a, b) => a - b);
    const totals = Object.entries(this.opStats).map(([op, s]) => ({
      op,
      count: s.count,
      errors: s.errors,
      avg_ms: s.count ? Math.round(s.latency_ms_total / s.count) : 0,
    }));
    return {
      running: this.running,
      rps: this.rps,
      observed_rps: Math.round(observedRps * 10) / 10,
      mix: this.mix,
      uptime_sec: this.running ? Math.round((now - this.startedAt) / 1000) : 0,
      latency_p50_ms: Math.round(quantile(allLat, 0.5)),
      latency_p95_ms: Math.round(quantile(allLat, 0.95)),
      latency_p99_ms: Math.round(quantile(allLat, 0.99)),
      total_ops: this.recentOpsTimes.length, // since process start (capped)
      by_op: totals,
      in_flight: this.inFlight,
      max_in_flight: MAX_IN_FLIGHT,
      dropped: this.dropped,
      recent_inserted: this.recentInsertIds.length,
      listings_sampled: this.listingsSample.length,
    };
  }

  setMix(mix) {
    const m = { ...DEFAULT_MIX, ...mix };
    for (const k of Object.keys(m)) m[k] = Math.max(0, Number(m[k]) || 0);
    if (m.browse + m.detail + m.insert + m.update === 0) m.browse = 1;
    this.mix = m;
  }

  async start({ rps, mix } = {}) {
    if (this.running) {
      this.stop();
    }
    const targetRps = Math.max(1, Math.min(MAX_RPS, Math.round(Number(rps) || 50)));
    if (mix) this.setMix(mix);
    this.rps = targetRps;
    this.running = true;
    this.startedAt = Date.now();
    // Reset rolling stats
    this.recentOpsTimes = [];
    this.recentLatencies = [];
    this.inFlight = 0;
    this.dropped = 0;
    this.opStats = {
      browse: emptyOpStats(),
      detail: emptyOpStats(),
      insert: emptyOpStats(),
      update: emptyOpStats(),
    };

    // Tick every 100ms; dispatch (rps/10) ops per tick.
    const intervalMs = 100;
    const opsPerTick = this.rps / (1000 / intervalMs);
    let opsCarry = 0;
    this.tickHandle = setInterval(() => {
      if (!this.running) return;
      opsCarry += opsPerTick;
      const fire = Math.floor(opsCarry);
      opsCarry -= fire;
      for (let i = 0; i < fire; i++) {
        if (this.inFlight >= MAX_IN_FLIGHT) {
          this.dropped++;
          continue;
        }
        this.inFlight++;
        this._dispatchOne().catch(() => {}).finally(() => { this.inFlight--; });
      }
      // Trim recent windows
      const now = Date.now();
      const cutoff = now - STATS_WINDOW_SEC * 1000;
      if (this.recentOpsTimes.length > 5000) {
        this.recentOpsTimes = this.recentOpsTimes.filter((t) => t >= cutoff);
      }
      if (this.recentLatencies.length > 5000) {
        this.recentLatencies = this.recentLatencies.filter((x) => x.ts >= cutoff);
      }
    }, intervalMs);

    this.log(`[loadgen] started: rps=${this.rps}, mix=${JSON.stringify(this.mix)}`);
    return this.status();
  }

  stop() {
    if (this.tickHandle) clearInterval(this.tickHandle);
    this.tickHandle = null;
    this.running = false;
    this.log("[loadgen] stopped");
    return this.status();
  }

  async _ensureListingsSample(db) {
    if (this.listingsSample.length > 0 && Date.now() - this.listingsSampleAt < 300_000) return;
    try {
      const docs = await db.collection("listings").aggregate([
        { $sample: { size: LISTINGS_SAMPLE_SIZE } },
        { $project: { _id: 1, id: 1, name: 1, displayName: 1, city: 1, country: 1, price: 1 } },
      ], { allowDiskUse: true }).toArray();
      if (docs.length > 0) {
        this.listingsSample = docs;
        this.listingsSampleAt = Date.now();
      }
    } catch (err) {
      this.log(`[loadgen] listings sample error: ${err.message}`);
    }
  }

  async _dispatchOne() {
    const op = pickWeighted(this.mix);
    const t0 = Date.now();
    let ok = true;
    try {
      const db = await this.getDbForPrimary();
      if (!db) throw new Error("no primary db");
      await this._ensureListingsSample(db);
      switch (op) {
        case "browse":  await this._opBrowse(db);  break;
        case "detail":  await this._opDetail(db);  break;
        case "insert":  await this._opInsert(db);  break;
        case "update":  await this._opUpdate(db);  break;
      }
    } catch (err) {
      ok = false;
      this.opStats[op].errors++;
      if (this.opStats[op].errors <= 3) {
        this.log(`[loadgen] ${op} error: ${err.message}`);
      }
    }
    const dt = Date.now() - t0;
    const stats = this.opStats[op];
    stats.count++;
    stats.latency_ms_total += dt;
    this.recentOpsTimes.push(t0);
    this.recentLatencies.push({ op, ms: dt, ts: t0, ok });
  }

  async _opBrowse(db) {
    const city = pickRandom(CITIES);
    const maxPrice = 100 + Math.floor(Math.random() * 400);
    await db.collection("listings")
      .find({ city, price: { $lte: maxPrice } },
            { projection: { displayName: 1, city: 1, country: 1, price: 1 } })
      .sort({ price: 1 })
      .limit(20)
      .toArray();
  }

  async _opDetail(db) {
    if (this.listingsSample.length === 0) return;
    const listing = pickRandom(this.listingsSample);
    // Avoid findOne({_id}): on partitioned listings collections the router
    // can fail with "trying to open a pruned relation" depending on how _id
    // was generated at seed time. The slug field `id` (or displayName as a
    // fallback) is what real booking-site detail pages actually use.
    const filter = listing.id
      ? { id: listing.id }
      : { displayName: listing.displayName || listing.name };
    await db.collection("listings")
      .find(filter, { projection: { displayName: 1, city: 1, country: 1, price: 1, description: 1 } })
      .limit(1)
      .toArray();
  }

  async _opInsert(db) {
    if (this.listingsSample.length === 0) return;
    const listing = pickRandom(this.listingsSample);
    const checkIn = randomDateBetween(7, 60);
    const nights = 1 + Math.floor(Math.random() * 7);
    const checkOut = new Date(checkIn.getTime() + nights * 86400_000);
    const doc = {
      listing_id: listing._id,
      listing_display_name: listing.displayName || listing.name || "",
      city: listing.city,
      country: listing.country,
      check_in: checkIn,
      check_out: checkOut,
      nights,
      total_price: nights * (listing.price || 100),
      guest_session_id: new ObjectId().toString(),
      source: "loadgen",
      created_at: new Date(),
    };
    const r = await db.collection("loadgen_bookings").insertOne(doc);
    if (r.insertedId) {
      this.recentInsertIds.push(r.insertedId);
      if (this.recentInsertIds.length > RECENT_INSERT_RING_SIZE) {
        this.recentInsertIds.shift();
      }
    }
  }

  async _opUpdate(db) {
    if (this.recentInsertIds.length === 0) return;
    const id = pickRandom(this.recentInsertIds);
    await db.collection("loadgen_bookings").updateOne(
      { _id: id },
      { $set: { confirmed_at: new Date(), status: "confirmed" } }
    );
  }
}

module.exports = { LoadGen, DEFAULT_MIX, MAX_RPS };

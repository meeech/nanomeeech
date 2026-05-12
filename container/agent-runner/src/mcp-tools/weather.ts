/**
 * Weather MCP tool — Open-Meteo (no API key, no signup).
 *
 * One tool: weather_get_forecast(latitude, longitude, days). Returns daily
 * high/low/precip/conditions in a compact JSON string the agent can fold
 * into a briefing or write into the notebook.
 */
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

const WEATHER_CODE: Record<number, string> = {
  0: 'clear sky',
  1: 'mainly clear',
  2: 'partly cloudy',
  3: 'overcast',
  45: 'fog',
  48: 'rime fog',
  51: 'light drizzle',
  53: 'moderate drizzle',
  55: 'dense drizzle',
  61: 'light rain',
  63: 'moderate rain',
  65: 'heavy rain',
  71: 'light snow',
  73: 'moderate snow',
  75: 'heavy snow',
  77: 'snow grains',
  80: 'rain showers',
  81: 'heavy rain showers',
  82: 'violent rain showers',
  85: 'snow showers',
  86: 'heavy snow showers',
  95: 'thunderstorm',
  96: 'thunderstorm with hail',
  99: 'thunderstorm with heavy hail',
};

export const weatherGetForecast: McpToolDefinition = {
  tool: {
    name: 'weather_get_forecast',
    description:
      'Fetch a daily forecast from Open-Meteo (no API key). Returns up to `days` days starting today: high/low temperature in °C, total precipitation in mm, and a one-word condition. Reads coordinates from the arguments; the household lat/long is recorded in CLAUDE.local.md.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        latitude: { type: 'number', description: 'Decimal latitude (e.g. 45.4688 for Montréal).' },
        longitude: { type: 'number', description: 'Decimal longitude (e.g. -73.6525 for Montréal).' },
        days: { type: 'number', description: 'Number of forecast days, 1–14 (default 3).' },
        timezone: { type: 'string', description: 'IANA timezone for day boundaries (default America/Toronto).' },
      },
      required: ['latitude', 'longitude'],
    },
  },
  async handler(args) {
    const lat = Number(args.latitude);
    const lon = Number(args.longitude);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return err('latitude and longitude must be numbers');
    }
    const days = Math.min(Math.max(Number(args.days ?? 3) || 3, 1), 14);
    const tz = (args.timezone as string) || 'America/Toronto';
    const url =
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
      `&daily=weathercode,temperature_2m_max,temperature_2m_min,precipitation_sum` +
      `&forecast_days=${days}&timezone=${encodeURIComponent(tz)}`;
    let res: Response;
    try {
      res = await fetch(url);
    } catch (e) {
      return err(`open-meteo fetch failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (!res.ok) return err(`open-meteo returned ${res.status} ${res.statusText}`);
    const body = (await res.json()) as {
      daily?: {
        time: string[];
        weathercode: number[];
        temperature_2m_max: number[];
        temperature_2m_min: number[];
        precipitation_sum: number[];
      };
    };
    const d = body.daily;
    if (!d) return err('open-meteo response missing daily block');
    const forecast = d.time.map((date, i) => ({
      date,
      high_c: d.temperature_2m_max[i],
      low_c: d.temperature_2m_min[i],
      precip_mm: d.precipitation_sum[i],
      condition: WEATHER_CODE[d.weathercode[i]] ?? `code ${d.weathercode[i]}`,
    }));
    return ok(JSON.stringify({ latitude: lat, longitude: lon, timezone: tz, forecast }, null, 2));
  },
};

registerTools([weatherGetForecast]);

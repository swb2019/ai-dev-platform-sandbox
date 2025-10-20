import { GET } from '@/app/healthz/route';

describe('healthz route', () => {
  beforeAll(() => {
    if (typeof Response === 'undefined') {
      class ResponseStub {
        private readonly body: unknown;
        readonly status: number;

        constructor(body: unknown, init?: ResponseInit) {
          this.body = body;
          this.status = init?.status ?? 200;
        }

        json(): Promise<unknown> {
          return Promise.resolve(this.body);
        }

        static json(payload: unknown, init?: ResponseInit) {
          return new ResponseStub(payload, init);
        }
      }

      // @ts-expect-error Jest environment may lack Response; provide minimal stub.
      globalThis.Response = ResponseStub;
    }
  });

  it('responds with an ok status payload', async () => {
    const response = GET();
    expect(response.status).toBe(200);

    const payload = (await response.json()) as { status: string };
    expect(payload).toEqual({ status: 'ok' });
  });
});

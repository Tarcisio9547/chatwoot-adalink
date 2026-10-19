import {
  buildNaoReceberCampanhasMessage,
  lerRespostaNaoReceberCampanhas,
  novoRequestId,
  podeNaoReceberCampanhas,
  solicitarNaoReceberCampanhas,
  TEXTO_ERRO_PADRAO,
  TEXTO_SEM_RESPOSTA,
} from '../naoReceberCampanhasMessage';

describe('#buildNaoReceberCampanhasMessage', () => {
  it('monta o pedido com telefone (sem espaços nas pontas) e requestId', () => {
    expect(
      buildNaoReceberCampanhasMessage({
        contact: { id: 1, phone_number: ' +5547991140001 ' },
        requestId: 'r-1',
      })
    ).toEqual({
      type: 'trama-nao-receber-campanhas',
      telefone: '+5547991140001',
      requestId: 'r-1',
    });
  });
});

describe('#novoRequestId', () => {
  it('gera ids diferentes a cada chamada', () => {
    const ids = new Set(Array.from({ length: 50 }, novoRequestId));
    expect(ids.size).toBe(50);
    ids.forEach(id => expect(id.length).toBeGreaterThan(8));
  });
});

describe('#podeNaoReceberCampanhas', () => {
  it('só com telefone preenchido', () => {
    expect(podeNaoReceberCampanhas({ phone_number: '+5547991140001' })).toBe(
      true
    );
    [
      null,
      undefined,
      {},
      { phone_number: '' },
      { phone_number: '   ' },
      { phone_number: null },
      { phone_number: 5547 },
    ].forEach(contact => expect(podeNaoReceberCampanhas(contact)).toBe(false));
  });
});

describe('#lerRespostaNaoReceberCampanhas', () => {
  it('ok com novo=true: entrou agora na lista, com o requestId do pedido', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        requestId: 'r-1',
        ok: true,
        novo: true,
      })
    ).toEqual({ requestId: 'r-1', ok: true, novo: true, error: '' });
  });

  it('ok com novo=false: já estava na lista', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        requestId: 'r-1',
        ok: true,
        novo: false,
      })
    ).toEqual({ requestId: 'r-1', ok: true, novo: false, error: '' });
  });

  it('resposta sem requestId volta com requestId vazio (o painel a descarta)', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        ok: true,
      }).requestId
    ).toBe('');
  });

  it('erro mostra o texto do CRM; sem texto, usa o padrão (nunca vazio)', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        requestId: 'r-1',
        ok: false,
        error: 'Você não tem permissão para tirar este número das campanhas.',
      })
    ).toEqual({
      requestId: 'r-1',
      ok: false,
      novo: false,
      error: 'Você não tem permissão para tirar este número das campanhas.',
    });
    ['', '  ', null, undefined, 5].forEach(error =>
      expect(
        lerRespostaNaoReceberCampanhas({
          type: 'trama-nao-receber-campanhas-done',
          ok: false,
          error,
        }).error
      ).toBe(TEXTO_ERRO_PADRAO)
    );
  });

  it('sucesso só com ok === true: ok "truthy" ou ausente NÃO vale', () => {
    ['true', 1, undefined, null].forEach(ok =>
      expect(
        lerRespostaNaoReceberCampanhas({
          type: 'trama-nao-receber-campanhas-done',
          ok,
        }).ok
      ).toBe(false)
    );
  });

  it('qualquer outra mensagem é ignorada', () => {
    [
      null,
      undefined,
      5,
      'x',
      [],
      {},
      { type: 'trama-ignorar-contato-done', ok: true },
    ].forEach(data => expect(lerRespostaNaoReceberCampanhas(data)).toBeNull());
  });
});

describe('#solicitarNaoReceberCampanhas', () => {
  let postMessage;
  const RESPOSTA = 'trama-nao-receber-campanhas-done';
  const enviar = (data, extra = {}) =>
    window.dispatchEvent(
      new MessageEvent('message', {
        data,
        origin: window.location.origin,
        source: window.parent,
        ...extra,
      })
    );

  beforeEach(() => {
    postMessage = vi
      .spyOn(window.parent, 'postMessage')
      .mockImplementation(() => {});
  });

  afterEach(() => {
    postMessage.mockRestore();
    vi.useRealTimers();
  });

  it('manda telefone e requestId ao CRM, só para o mesmo origin', () => {
    const { requestId } = solicitarNaoReceberCampanhas({
      telefone: '+5547991140001',
    });
    expect(postMessage).toHaveBeenCalledWith(
      {
        type: 'trama-nao-receber-campanhas',
        telefone: '+5547991140001',
        requestId,
      },
      window.location.origin
    );
  });

  it('resolve com a resposta do MESMO pedido', async () => {
    const { requestId, promessa } = solicitarNaoReceberCampanhas({
      telefone: '+5547991140001',
    });
    enviar({ type: RESPOSTA, requestId, ok: true, novo: true });
    expect(await promessa).toEqual({
      requestId,
      ok: true,
      novo: true,
      error: '',
    });
  });

  it('ignora resposta de outro pedido, outro origin ou outra janela', async () => {
    vi.useFakeTimers();
    const { requestId, promessa } = solicitarNaoReceberCampanhas({
      telefone: '+5547991140001',
    });
    const ok = { type: RESPOSTA, requestId, ok: true, novo: true };
    enviar({ ...ok, requestId: 'de-outro' });
    enviar(ok, { origin: 'https://site-malicioso.example' });
    enviar(ok, { source: null });
    // nenhuma valeu: só o timeout encerra
    await vi.advanceTimersByTimeAsync(15000);
    expect(await promessa).toMatchObject({
      ok: false,
      error: TEXTO_SEM_RESPOSTA,
    });
  });

  it('sem resposta no prazo: ok=false com o texto de "CRM não respondeu"', async () => {
    vi.useFakeTimers();
    const { promessa } = solicitarNaoReceberCampanhas({
      telefone: '+55',
      timeoutMs: 500,
    });
    await vi.advanceTimersByTimeAsync(500);
    expect(await promessa).toMatchObject({
      ok: false,
      novo: false,
      error: TEXTO_SEM_RESPOSTA,
    });
  });

  it('cancelar solta o ouvinte e resolve com null; resposta tardia não faz nada', async () => {
    const remover = vi.spyOn(window, 'removeEventListener');
    const { requestId, promessa, cancelar } = solicitarNaoReceberCampanhas({
      telefone: '+5547991140001',
    });
    cancelar();
    expect(await promessa).toBeNull();
    expect(remover.mock.calls.some(c => c[0] === 'message')).toBe(true);
    enviar({ type: RESPOSTA, requestId, ok: true, novo: true });
    remover.mockRestore();
  });

  it('depois de resolvida, solta o ouvinte (não acumula ouvintes a cada clique)', async () => {
    const remover = vi.spyOn(window, 'removeEventListener');
    const { requestId, promessa } = solicitarNaoReceberCampanhas({
      telefone: '+5547991140001',
    });
    enviar({ type: RESPOSTA, requestId, ok: true });
    await promessa;
    expect(remover.mock.calls.filter(c => c[0] === 'message')).toHaveLength(1);
    remover.mockRestore();
  });
});

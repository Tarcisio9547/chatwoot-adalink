import {
  buildNaoReceberCampanhasMessage,
  lerRespostaNaoReceberCampanhas,
  novoRequestId,
  podeNaoReceberCampanhas,
  TEXTO_ERRO_PADRAO,
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

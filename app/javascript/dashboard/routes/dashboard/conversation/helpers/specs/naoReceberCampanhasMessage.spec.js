import {
  buildNaoReceberCampanhasMessage,
  lerRespostaNaoReceberCampanhas,
  podeNaoReceberCampanhas,
  TEXTO_ERRO_PADRAO,
} from '../naoReceberCampanhasMessage';

describe('#buildNaoReceberCampanhasMessage', () => {
  it('monta o pedido com o telefone do contato, sem espaços nas pontas', () => {
    expect(
      buildNaoReceberCampanhasMessage({
        contact: { id: 1, phone_number: ' +5547991140001 ' },
      })
    ).toEqual({
      type: 'trama-nao-receber-campanhas',
      telefone: '+5547991140001',
    });
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
  it('ok com novo=true: entrou agora na lista', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        ok: true,
        novo: true,
      })
    ).toEqual({ ok: true, novo: true, error: '' });
  });

  it('ok com novo=false: já estava na lista', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        ok: true,
        novo: false,
      })
    ).toEqual({ ok: true, novo: false, error: '' });
  });

  it('erro mostra o texto do CRM; sem texto, usa o padrão (nunca vazio)', () => {
    expect(
      lerRespostaNaoReceberCampanhas({
        type: 'trama-nao-receber-campanhas-done',
        ok: false,
        error: 'Você não tem permissão para tirar este número das campanhas.',
      })
    ).toEqual({
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

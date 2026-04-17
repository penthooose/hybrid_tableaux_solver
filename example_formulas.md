## Here are some examples to run with the Solver:

Paste any line directly into the GUI field **Formula**.

### Easy (propositional)

- `p`
- `not p`
- `p and q`
- `p or q`
- `p -> q`
- `p <-> q`
- `p and not p`
- `(p or q) and not p`
- `(p or q) and (not p or r)`
- `(p -> q) and p and not q`
- `(p <-> q) and p and not q`
- `(p or q or r) and not q`
- `((p -> q) and (q -> r)) -> (p -> r)`
- `(p and q) -> p`
- `(p and q) -> q`

### Easy–Medium (predicates without quantifiers)

- `P(a)`
- `P(a) and Q(b)`
- `P(a) -> Q(a)`
- `P(a) and not P(a)`
- `P(a,b) -> R(a,b)`
- `accept_city(agent1,citya)`
- `accept_city(agent1,citya) and accept_leader(agent1,leader1)`
- `accept_team(agent1,leader1,citya,n2) -> accept_city(agent1,citya)`

### Medium (quantifiers with finite domains)

- `forall x in {a,b}: P(x) -> Q(x)`
- `forall x in {a,b}: P(x) and Q(x)`
- `exists x in {a,b,c}: P(x)`
- `exists x in {a,b,c}: P(x) and not Q(x)`
- `forall x in {a,b}: P(x) -> exists y in {a,b}: Q(x,y)`
- `forall x in {a,b,c}: exists y in {a,b,c}: R(x,y)`
- `exists x in {a,b}: forall y in {a,b}: S(x,y)`
- `forall x in {a,b}: P(y) -> Q(x)`
- `forall x in {a,b}: P(x) -> Q(x) and R(x)`
- `forall x in {a,b}: (P(x) -> Q(x)) and (Q(x) -> R(x))`

### Medium–Hard (mixed nested structure)

- `(forall x in {a,b}: P(x) -> Q(x)) and (exists x in {a,b}: P(x))`
- `(forall x in {a,b}: P(x) -> Q(x)) and (exists x in {a,b}: P(x) and not Q(x))`
- `forall x in {a,b,c}: (P(x) or Q(x)) and (not P(x) or R(x))`
- `forall x in {a,b,c}: (P(x) -> Q(x)) and (Q(x) -> R(x)) and (R(x) -> S(x))`
- `exists x in {a,b,c}: P(x) and forall y in {a,b,c}: P(y) -> Q(y)`
- `forall x in {a,b}: exists y in {a,b}: (P(x) and Q(y)) -> R(x,y)`
- `forall x in {a,b,c}: exists y in {a,b,c}: (Edge(x,y) and not Edge(y,x))`
- `(exists x in {a,b,c}: P(x)) and (forall x in {a,b,c}: P(x) -> Q(x)) and (forall x in {a,b,c}: Q(x) -> R(x))`

### Harder benchmark-like formulas (still GUI-friendly)

- `(forall x in {a,b,c,d}: P(x) -> Q(x)) and (forall x in {a,b,c,d}: Q(x) -> R(x)) and (exists x in {a,b,c,d}: P(x))`
- `(forall x in {a,b,c,d}: A(x) -> B(x)) and (forall x in {a,b,c,d}: B(x) -> C(x)) and (forall x in {a,b,c,d}: C(x) -> D(x)) and (exists x in {a,b,c,d}: A(x) and not D(x))`
- `forall x in {a,b,c,d}: (P(x) or Q(x)) and (not P(x) or R(x)) and (not Q(x) or R(x))`
- `(forall x in {a,b,c,d}: ExistsWitness(x) -> P(x)) and (exists x in {a,b,c,d}: ExistsWitness(x)) and (forall x in {a,b,c,d}: P(x) -> Q(x))`
- `(forall x in {a,b,c,d}: accept_city(agent1,x) -> good_city(x)) and (exists x in {a,b,c,d}: accept_city(agent1,x)) and (forall x in {a,b,c,d}: good_city(x) -> safe_city(x))`
- `(forall a in {agent1,agent2}: forall c in {citya,cityb}: accept_city(a,c) -> eligible(a,c)) and (exists a in {agent1,agent2}: exists c in {citya,cityb}: accept_city(a,c))`

### Unsat stress snippets

- `forall x in {a,b,c}: P(x) and not P(x)`
- `(forall x in {a,b,c}: P(x) -> Q(x)) and (exists x in {a,b,c}: P(x) and not Q(x))`
- `(p -> q) and p and not q`
- `(p <-> q) and p and not q`
- `exists x in {a,b}: P(x) and forall x in {a,b}: not P(x)`

import itertools

from collections import Counter
from graphbrain import hedge
from graphbrain.utils.lemmas import lemma
from graphbrain.semsim import match_semsim


FUNS = {'var', 'atoms', 'lemma', 'any', 'semsim'}


def is_wildcard(atom):
    """Check if this atom defines a wildcard, i.e. if its root is a pattern matchers.
    (\*, ., ..., if it is surrounded by parenthesis or variable label starting with an uppercase letter)
    """
    if atom.atom:
        return atom.parens or atom[0][0] in {'*', '.'} or atom[0][0].isupper()
    else:
        return False


def is_fun_pattern(edge):
    if edge.atom:
        return False
    return str(edge[0]) in FUNS


def is_pattern(edge):
    """Check if this edge defines a pattern, i.e. if it includes at least
    one pattern matchers.

    Pattern matchers are:
    - '\*', '.', '(\*)', '...'
    - variables (atom label starting with an uppercase letter)
    - argument role matchers (unordered argument roles surrounded by curly brackets)
    - functional patterns (var, atoms, lemma, ...)
    """
    if edge.atom:
        return is_wildcard(edge) or '{' in edge.argroles()
    elif is_fun_pattern(edge):
        return True
    else:
        return any(is_pattern(item) for item in edge)


def is_unordered_pattern(edge):
    """Check if this edge defines an unordered pattern, i.e. if it includes at least
    one instance of unordered argument roles surrounded by curly brackets.
    """
    if edge.atom:
        return '{' in edge.argroles()
    else:
        return any(is_unordered_pattern(item) for item in edge)

def is_full_pattern(edge):
    """Check if every atom is a pattern matchers.

    Pattern matchers are:
    '\*', '.', '(\*)', '...', variables (atom label starting with an
    uppercase letter) and functional patterns.
    """
    if edge.atom:
        return is_pattern(edge)
    else:
        return all(is_pattern(item) for item in edge)


def apply_vars(edge, variables):
    if edge.atom:
        if is_pattern(edge):
            varname = _varname(edge)
            if len(varname) > 0 and varname in variables:
                return variables[varname]
        return edge
    else:
        return hedge([apply_vars(subedge, variables) for subedge in edge])


def _matches_atomic_pattern(edge, atomic_pattern):
    ap_parts = atomic_pattern.parts()

    if len(ap_parts) == 0 or len(ap_parts[0]) == 0:
        return False

    # structural match
    struct_code = ap_parts[0][0]
    if struct_code == '.':
        if edge.not_atom:
            return False
    elif atomic_pattern.parens:
        if edge.atom:
            return False
    elif struct_code != '*' and not struct_code.isupper():
        if edge.not_atom:
            return False
        if edge.root() != atomic_pattern.root():
            return False

    # role match
    if len(ap_parts) > 1:
        pos = 1

        # type match
        ap_role = atomic_pattern.role()
        ap_type = ap_role[0]
        e_type = edge.type()
        n = len(ap_type)
        if len(e_type) < n or e_type[:n] != ap_type:
            return False

        e_atom = edge.inner_atom()

        if len(ap_role) > 1:
            e_role = e_atom.role()
            # check if edge role has enough parts to satisfy the wildcard
            # specification
            if len(e_role) < len(ap_role):
                return False

            # argroles match
            if ap_type[0] in {'B', 'P'}:
                ap_argroles_parts = ap_role[1].split('-')
                if len(ap_argroles_parts) == 1:
                    ap_argroles_parts.append('')
                ap_negroles = ap_argroles_parts[1]

                # fixed order?
                ap_argroles_posopt = ap_argroles_parts[0]
                e_argroles = e_role[1]
                if len(ap_argroles_posopt) > 0 and ap_argroles_posopt[0] == '{':
                    ap_argroles_posopt = ap_argroles_posopt[1:-1]
                else:
                    ap_argroles_posopt = ap_argroles_posopt.replace(',', '')
                    if len(e_argroles) > len(ap_argroles_posopt):
                        return False
                    else:
                        return ap_argroles_posopt.startswith(e_argroles)

                ap_argroles_parts = ap_argroles_posopt.split(',')
                ap_posroles = ap_argroles_parts[0]
                ap_argroles = set(ap_posroles) | set(ap_negroles)
                for argrole in ap_argroles:
                    min_count = ap_posroles.count(argrole)
                    # if there are argrole exclusions
                    fixed = ap_negroles.count(argrole) > 0
                    count = e_argroles.count(argrole)
                    if count < min_count:
                        return False
                    # deal with exclusions
                    if fixed and count > min_count:
                        return False
                pos = 2

            # match rest of role
            while pos < len(ap_role):
                if e_role[pos] != ap_role[pos]:
                    return False
                pos += 1

    # match rest of atom
    if len(ap_parts) > 2:
        e_parts = e_atom.parts()
        # check if edge role has enough parts to satisfy the wildcard
        # specification
        if len(e_parts) < len(ap_parts):
            return False

        while pos < len(ap_parts):
            if e_parts[pos] != ap_parts[pos]:
                return False
            pos += 1

    return True


def _varname(atom):
    if not atom.atom:
        return ''
    label = atom.parts()[0]
    if len(label) == 0:
        return label
    elif label[0] in {'*', '.'}:
        return label[1:]
    elif label[:3] == '...':
        return label[3:]
    elif label[0].isupper():
        return label
    else:
        return ''


# remove pattern functions from pattern, so that .argroles() works normally
def _defun_pattern_argroles(edge):
    if edge.atom:
        return edge
    
    if edge[0].argroles() != '':
        return edge

    if is_fun_pattern(edge):
        fun = edge[0].root()
        if fun == 'atoms':
            for atom in edge.atoms():
                argroles = atom.argroles()
                if argroles != '':
                    return atom
            # if no atom with argroles is found, just return the first one
            return edge[1]
        else:
            return hedge([edge[0], _defun_pattern_argroles(edge[1])] + list(edge[2:]))
    else:
        return hedge([_defun_pattern_argroles(subedge) for subedge in edge])


def _match_by_argroles(edge, pattern, role_counts, min_vars, hg, matched=(), curvars=None, root_edge=None):
    if curvars is None:
        curvars = {}

    if len(role_counts) == 0:
        return [curvars]

    argrole, n = role_counts[0]

    # match connector
    if argrole == 'X':
        eitems = [edge[0]]
        pitems = [pattern[0]]
    # match any argrole
    elif argrole == '*':
        eitems = [e for e in edge if e not in matched]
        pitems = pattern[-n:]
    # match specific argrole
    else:
        eitems = edge.edges_with_argrole(argrole)
        pitems = _defun_pattern_argroles(pattern).edges_with_argrole(argrole)

    if len(eitems) < n:
        if len(curvars) >= min_vars:
            return [curvars]
        else:
            return []

    result = []

    for perm in tuple(itertools.permutations(eitems, r=n)):
        perm_result = [{}]
        for i, eitem in enumerate(perm):
            pitem = pitems[i]
            item_result = []
            for variables in perm_result:
                item_result += _match_pattern(eitem, pitem, {**curvars, **variables}, hg=hg, root_edge=root_edge)
            perm_result = item_result
            if len(item_result) == 0:
                break

        for variables in perm_result:
            result += _match_by_argroles(edge, pattern, role_counts[1:], min_vars, hg, matched + perm,
                                         {**curvars, **variables}, root_edge=root_edge)
    
    return result


def _match_atoms(atom_patterns, atoms, curvars, hg, root_edge=None, matched_atoms=None) -> list[dict]:
    if matched_atoms is None:
        matched_atoms = []

    if len(atom_patterns) == 0:
        return [curvars]
    
    results = []
    atom_pattern = atom_patterns[0]

    for atom in atoms:
        if atom not in matched_atoms:
            svars = _match_pattern(atom, atom_pattern, curvars, hg=hg, root_edge=root_edge)
            for variables in svars:
                results += _match_atoms(
                    atom_patterns[1:], atoms, {**curvars, **variables}, hg, root_edge, matched_atoms + [atom])

    return results


# TODO: deal with argroles
def _match_lemma(lemma_pattern, edge, curvars, hg):
    if hg is None:
        raise RuntimeError('Lemma pattern function requires hypergraph.')

    if edge.not_atom:
        return []

    _lemma = lemma(hg, edge, same_if_none=True)

    # add argroles to _lemma if needed
    ar = edge.argroles()
    if ar != '':
        parts = _lemma.parts()
        parts[1] = '{}.{}'.format(parts[1], ar)
        _lemma = hedge('/'.join(parts))

    if _matches_atomic_pattern(_lemma, lemma_pattern):
        return [curvars]

    return []


def _matches_fun_pat(edge, fun_pattern, curvars, hg, root_edge) -> list[dict]:
    fun = fun_pattern[0].root()
    if fun == 'var':
        if len(fun_pattern) != 3:
            raise RuntimeError('var pattern function must have two arguments')
        pattern = fun_pattern[1]
        var_name = fun_pattern[2].root()
        if edge.not_atom and str(edge[0]) == 'var' and len(edge) == 3 and str(edge[2]) == var_name:
            this_var = {var_name: edge[1]}
            return _match_pattern(edge[1], pattern, curvars={**curvars, **this_var}, hg=hg, root_edge=root_edge)
        else:
            this_var = {var_name: edge}
            return _match_pattern(edge, pattern, curvars={**curvars, **this_var}, hg=hg, root_edge=root_edge)
    elif fun == 'atoms':
        atoms = edge.atoms()
        atom_patterns = fun_pattern[1:]
        return _match_atoms(atom_patterns, atoms, curvars, hg, root_edge=root_edge)
    elif fun == 'lemma':
        return _match_lemma(fun_pattern[1], edge, curvars, hg)
    elif fun == 'semsim':
        return match_semsim(fun_pattern[1:], edge, curvars, hg)
    elif fun == 'any':
        for pattern in fun_pattern[1:]:
            matches = _match_pattern(edge, pattern, curvars=curvars, hg=hg, root_edge=root_edge)
            if len(matches) > 0:
                return matches
        return []
    else:
        raise RuntimeError('Unknown pattern function: {}'.format(fun))


def _match_pattern(edge, pattern, curvars=None, hg=None, root_edge=None):
    if curvars is None:
        curvars = {}

    # if root_edge is not specified, it is assumed that edge is its own root
    if root_edge is None:
        root_edge = edge

    # atomic patterns
    if pattern.atom:
        if _matches_atomic_pattern(edge, pattern):
            variables = {}
            if is_pattern(pattern):
                varname = _varname(pattern)
                if len(varname) > 0:
                    if varname in curvars and curvars[varname] != edge:
                        return []
                    variables[varname] = edge
            return [{**curvars, **variables}]
        else:
            return []

    # functional patterns
    if is_fun_pattern(pattern):
        return _matches_fun_pat(edge, pattern, curvars, hg, root_edge)

    min_len = len(pattern)
    max_len = min_len
    # open-ended?
    if pattern[-1].to_str() == '...':
        pattern = hedge(pattern[:-1])
        min_len -= 1
        max_len = float('inf')

    result = [{}]
    argroles_posopt = _defun_pattern_argroles(pattern)[0].argroles().split('-')[0]
    if len(argroles_posopt) > 0 and argroles_posopt[0] == '{':
        match_by_order = False
        argroles_posopt = argroles_posopt[1:-1]
    else:
        match_by_order = True
    argroles = argroles_posopt.split(',')[0]
    argroles_opt = argroles_posopt.replace(',', '')

    if len(argroles) > 0:
        min_len = 1 + len(argroles)
        max_len = float('inf')
    else:
        match_by_order = True

    if len(edge) < min_len or len(edge) > max_len:
        return []

    # match by order
    if match_by_order:
        for i, pitem in enumerate(pattern):
            eitem = edge[i]
            _result = []
            for variables in result:
                if pitem.atom:
                    varname = _varname(pitem)
                    if varname in curvars:
                        if curvars[varname] != eitem:
                            continue
                    elif varname in variables:
                        if variables[varname] != eitem:
                            continue
                    elif _matches_atomic_pattern(eitem, pitem):
                        if len(varname) > 0 and varname[0].isupper():
                            variables[varname] = eitem
                    else:
                        continue
                    _result.append(variables)
                else:
                    _result +=  _match_pattern(eitem, pitem, {**curvars, **variables}, hg=hg, root_edge=root_edge)
            result = _result
    # match by argroles
    else:
        result = []
        # match connectors first
        econn = edge[0]
        pconn = pattern[0]
        for variables in _match_pattern(econn, pconn, curvars, hg=hg, root_edge=root_edge):
            role_counts = Counter(argroles_opt).most_common()
            unknown_roles = (len(pattern) - 1) - len(argroles_opt)
            if unknown_roles > 0:
                role_counts.append(('*', unknown_roles))
            # add connector pseudo-argrole
            role_counts = [('X', 1)] + role_counts
            sresult = _match_by_argroles(
                edge, pattern, role_counts, len(argroles), hg, curvars={**curvars, **variables}, root_edge=root_edge)
            for svars in sresult:
                result.append({**variables, **svars})

    unique_vars = []
    for variables in result:
        v = {**curvars, **variables}
        if v not in unique_vars:
            unique_vars.append(v)
    return unique_vars


def _normalize_fun_patterns(pattern):
    if pattern.atom:
        return pattern

    pattern = hedge([_normalize_fun_patterns(subpattern) for subpattern in pattern])

    if is_fun_pattern(pattern):
        if str(pattern[0]) == 'lemma':
            if is_fun_pattern(pattern[1]) and str(pattern[1][0]) == 'any':
                new_pattern = ['any']
                for alternative in pattern[1][1:]:
                    new_pattern.append(['lemma', alternative])
                return hedge(new_pattern)

    return pattern


def match_pattern(edge, pattern, curvars=None, hg=None, root_edge=None):
    """Matches an edge to a pattern. This means that, if the edge fits the
    pattern, then a dictionary will be returned with the values for each
    pattern variable. If the pattern specifies no variables but the edge
    matches it, then an empty dictionary is returned. If the edge does
    not match the pattern, None is returned.

    Patterns are themselves edges. They can match families of edges
    by employing special atoms:

    -> '\*' represents a general wildcard (matches any entity)

    -> '.' represents an atomic wildcard (matches any atom)

    -> '(\*)' represents an edge wildcard (matches any edge)

    -> '...' at the end indicates an open-ended pattern.

    The wildcards ('\*', '.' and '(\*)') can be used to specify variables,
    for example '\*x', '(CLAIM)' or '.ACTOR'. In case of a match, these
    variables are assigned the hyperedge they correspond to. For example,

    (1) the edge: (is/Pd (my/Mp name/Cn) mary/Cp)
    applied to the pattern: (is/Pd (my/Mp name/Cn) \*NAME)
    produces the result: {'NAME', mary/Cp}

    (2) the edge: (is/Pd (my/Mp name/Cn) mary/Cp)
    applied to the pattern: (is/Pd (my/Mp name/Cn) (NAME))
    produces the result: {}

    (3) the edge: (is/Pd (my/Mp name/Cn) mary/Cp)
    applied to the pattern: (is/Pd . \*NAME)
    produces the result: None
    """
    edge = hedge(edge)
    pattern = hedge(pattern)
    pattern = _normalize_fun_patterns(pattern)
    root_edge = hedge(root_edge)
    return _match_pattern(edge, pattern, curvars=curvars, hg=hg, root_edge=root_edge)


def edge_matches_pattern(edge, pattern, hg=None, root_edge=None):
    """Check if an edge matches a pattern.

    Patterns are themselves edges. They can match families of edges
    by employing special atoms:

    -> '\*' represents a general wildcard (matches any entity)

    -> '.' represents an atomic wildcard (matches any atom)

    -> '(\*)' represents an edge wildcard (matches any edge)

    -> '...' at the end indicates an open-ended pattern.

    The pattern can be any valid hyperedge, including the above special atoms.
    Examples: (is/Pd graphbrain/C .)
    (says/Pd * ...)
    """
    result = match_pattern(edge, pattern, hg=hg, root_edge=root_edge)
    return len(result) > 0


def edge2pattern(edge, root=False, subtype=False):
    if root and edge.atom:
        root_str = edge.root()
    else:
        root_str = '*'
    if subtype:
        et = edge.type()
    else:
        et = edge.mtype()
    pattern = '{}/{}'.format(root_str, et)
    ar = edge.argroles()
    if ar == '':
        return hedge(pattern)
    else:
        return hedge('{}.{}'.format(pattern, ar))


def inner_edge_matches_pattern(edge, pattern, hg=None):
    if edge.atom:
        return False
    for subedge in edge:
        if edge_matches_pattern(subedge, pattern, hg=hg):
            return True
    for subedge in edge:
        if inner_edge_matches_pattern(subedge, pattern, hg=hg):
            return True
    return False


class PatternCounter:
    def __init__(self,
                 depth=2,
                 count_subedges=True,
                 expansions=None,
                 match_roots=None,
                 match_subtypes=None):
        self.patterns = Counter()
        self.depth = depth
        self.count_subedges = count_subedges
        if expansions is None:
            self.expansions = {'*'}
        else:
            self.expansions = expansions
        if match_roots is None:
            self.match_roots = set()
        else:
            self.match_roots = match_roots
        if match_subtypes is None:
            self.match_subtypes = set()
        else:
            self.match_subtypes = match_subtypes

    def _matches_expansions(self, edge):
        for expansion in self.expansions:
            if edge_matches_pattern(edge, expansion):
                return True
        return False

    def _force_subtypes(self, edge):
        force_subtypes = False
        for st_pattern in self.match_subtypes:
            if edge_matches_pattern(edge, st_pattern):
                force_subtypes = True
        return force_subtypes

    def _force_root_expansion(self, edge):
        force_root = False
        force_expansion = False
        for root_pattern in self.match_roots:
            if edge_matches_pattern(edge, root_pattern):
                force_root = True
                force_expansion = True
            elif inner_edge_matches_pattern(edge, root_pattern):
                force_expansion = True
        return force_root, force_expansion

    def _list2patterns(self, ledge, depth=1, force_expansion=False, force_root=False, force_subtypes=False):
        if depth > self.depth:
            return []

        first = ledge[0]

        f_force_subtypes = force_subtypes | self._force_subtypes(first)

        f_force_root, f_force_expansion = self._force_root_expansion(first)
        f_force_root |= force_root
        f_force_expansion |= force_expansion
        root = force_root | f_force_root

        if f_force_expansion and not first.atom:
            hpats = []
        else:
            hpats = [edge2pattern(first, root=root, subtype=f_force_subtypes)]

        if not first.atom and (self._matches_expansions(first) or
                                    f_force_expansion):
            hpats += self._list2patterns(list(first), depth + 1, force_expansion=f_force_expansion,
                                         force_root=f_force_root, force_subtypes=f_force_subtypes)
        if len(ledge) == 1:
            patterns = [[hpat] for hpat in hpats]
        else:
            patterns = []
            for pattern in self._list2patterns(ledge[1:], depth=depth, force_expansion=force_expansion,
                                               force_root=force_root, force_subtypes=force_subtypes):
                for hpat in hpats:
                    patterns.append([hpat] + pattern)
        return patterns

    def _edge2patterns(self, edge):
        force_subtypes = self._force_subtypes(edge)
        force_root, _ = self._force_root_expansion(edge)
        return list(hedge(pattern)
                    for pattern
                    in self._list2patterns(list(edge.normalized()), force_subtypes=force_subtypes,
                                           force_root=force_root, force_expansion=False))

    def count(self, edge):
        edge = hedge(edge)
        if edge.not_atom:
            if self._matches_expansions(edge):
                for pattern in self._edge2patterns(edge):
                    self.patterns[hedge(pattern)] += 1
            if self.count_subedges:
                for subedge in edge:
                    self.count(subedge)

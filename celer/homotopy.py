# Author: Mathurin Massias <mathurin.massias@gmail.com>
#         Alexandre Gramfort <alexandre.gramfort@inria.fr>
#         Joseph Salmon <joseph.salmon@telecom-paristech.fr>
# License: BSD 3 clause

import time
import warnings
import numpy as np

from scipy import sparse
from sklearn.utils import check_array
from sklearn.exceptions import ConvergenceWarning

from .sparse import celer_sparse
from .dense import celer_dense


def celer_path(X, y, eps=1e-3, n_alphas=100, alphas=None,
               coef_init=None, max_iter=20,
               gap_freq=10, max_epochs=50000, p0=10, verbose=0,
               verbose_inner=0, tol=1e-6, prune=0, return_thetas=False,
               monitor=False, X_offset=None, X_scale=None):
    """Compute Lasso path with Celer as inner solver.

    Parameters
    ----------
    X : {array-like, sparse matrix}, shape (n_samples, n_features)
        Training data. Pass directly as Fortran-contiguous data or column
        sparse format (CSC) to avoid unnecessary memory duplication.

    y : ndarray, shape (n_samples,)
        Target values

    eps : float, optional
        Length of the path. ``eps=1e-3`` means that
        ``alpha_min = 1e-3 * alpha_max``

    n_alphas : int, optional
        Number of alphas along the regularization path

    alphas : ndarray, optional
        List of alphas where to compute the models.
        If ``None`` alphas are set automatically

    coef_init : ndarray, shape (n_features,) | None, optional, (defualt=None)
        Initial value of coefficients. If None, np.zeros(n_features) is used.

    max_iter : int, optional
        The maximum number of iterations (subproblem definitions)

    gap_freq : int, optional
        Number of coordinate descent epochs between each duality gap
        computations.

    max_epochs : int, optional
        Maximum number of CD epochs on each subproblem.

    p0 : int, optional
        First working set size.

    verbose : bool or integer, optional
        Amount of verbosity.

    verbose_inner : bool or integer
        Amount of verbosity in the inner solver.

    tol : float, optional
        The tolerance for the optimization: the solver runs until the duality
        gap is smaller than ``tol`` or the maximum number of iteration is
        reached.

    prune : 0 | 1, optional
        Whether or not to use pruning when growing working sets.

    return_thetas : bool, optional
        If True, dual variables along the path are returned.

    monitor : bool, optional (default=False)
        Whether to return timings and gaps for each alpha. Used only for single
        alpha.

    X_offset : np.array, shape (n_features,), optional
        Used to center sparse X without breaking sparsity. Mean of each column.
        See sklearn.linear_model.base._preprocess_data().

    X_scale: np.array, shape (n_features,), optional
        Used to scale centered sparse X without breaking sparsity. Norm of each
        centered column. See sklearn.linear_model.base._preprocess_data().

    Returns
    -------
    alphas : array, shape (n_alphas,)
        The alphas along the path where models are computed.

    coefs : array, shape (n_features, n_alphas)
        Coefficients along the path.

    dual_gaps : array, shape (n_alphas,)
        Duality gaps returned by the solver along the path.

    thetas : array, shape (n_alphas, n_samples)
        The dual variables along the path.
        (Is returned only when ``return_thetas`` is set to True).
    """
    data_is_sparse = sparse.issparse(X)
    # Contrary to sklearn we always check input
    X = check_array(X, 'csc', dtype=[np.float64, np.float32],
                    order='F', copy=False)
    y = check_array(y, 'csc', dtype=X.dtype.type, order='F', copy=False,
                    ensure_2d=False)

    n_samples, n_features = X.shape

    if X_offset is not None:
        # As sparse matrices are not actually centered we need this
        # to be passed to the CD solver.
        X_sparse_scaling = X_offset / X_scale
        X_sparse_scaling = np.asarray(X_sparse_scaling, dtype=X.dtype)
    else:
        X_sparse_scaling = np.zeros(n_features, dtype=X.dtype)

    if alphas is None:
        alpha_max = np.max(np.abs(X.T.dot(y))) / n_samples
        alphas = alpha_max * np.logspace(0, np.log10(eps), n_alphas,
                                         dtype=X.dtype)
    else:
        alphas = np.sort(alphas)[::-1]

    n_alphas = len(alphas)

    coefs = np.zeros((n_features, n_alphas), order='F', dtype=X.dtype)
    thetas = np.zeros((n_alphas, n_samples), dtype=X.dtype)
    dual_gaps = np.zeros(n_alphas)
    all_times = np.zeros(n_alphas)
    if monitor:
        gaps_per_alpha, times_per_alpha = [], []

    # do not skip alphas[0], it is not always alpha_max
    for t in range(n_alphas):
        if verbose:
            print("#" * 60)
            print(" ##### Computing %dth alpha" % (t + 1))
            print("#" * 60)
        if t > 0:
            w_init = coefs[:, t - 1].copy()
            p0 = max(len(np.where(w_init != 0)[0]), 1)
        else:
            if coef_init is not None:
                w_init = coef_init.copy()
                p0 = max((w_init != 0.).sum(), p0)
            else:
                w_init = np.zeros(n_features, dtype=X.dtype)

        alpha = alphas[t]
        t0 = time.time()
        if data_is_sparse:
            sol = celer_sparse(
                X.data, X.indices, X.indptr, X_sparse_scaling, y, alpha,
                w_init,
                max_iter=max_iter, gap_freq=gap_freq,  max_epochs=max_epochs,
                p0=p0, verbose=verbose, verbose_inner=verbose_inner,
                use_accel=1, tol=tol, prune=prune)
        else:
            sol = celer_dense(
                X, y, alpha, w_init, max_iter=max_iter, gap_freq=gap_freq,
                max_epochs=max_epochs, p0=p0, verbose=verbose,
                verbose_inner=verbose_inner, use_accel=1, tol=tol, prune=prune)

        all_times[t] = time.time() - t0
        coefs[:, t], thetas[t], dual_gaps[t] = sol[0], sol[1], sol[2][-1]
        if monitor:
            gaps_per_alpha.append(sol[2])
            times_per_alpha.append(sol[3])

        if dual_gaps[t] > tol:
            warnings.warn('Objective did not converge.' +
                          ' You might want' +
                          ' to increase the number of iterations.' +
                          ' Fitting data with very small alpha' +
                          ' may cause precision problems.',
                          ConvergenceWarning)

    results = alphas, coefs, dual_gaps
    if return_thetas:
        results += (thetas,)
        if monitor:
            results += (gaps_per_alpha, times_per_alpha)

    return results

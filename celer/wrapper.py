# Author: Mathurin Massias <mathurin.massias@gmail.com>
#         Alexandre Gramfort <alexandre.gramfort@inria.fr>
#         Joseph Salmon <joseph.salmon@telecom-paristech.fr>
# License: BSD 3 clause

import numpy as np

from .homotopy import celer_path


def celer(X, y, alpha, w_init=None, max_iter=100, gap_freq=10,
          max_epochs=50000, p0=10, verbose=1, verbose_inner=0,
          tol=1e-6, prune=0):
    """
    Compute the Lasso solution with the Celer algorithm.

    The minimized objective function is::

        ||y - X w||_2^2 / (2 * n_samples) + alpha * ||w||_1

    Parameters
    ----------
    X : {array-like, sparse matrix}, shape (n_samples, n_features)
        Training data. Pass directly as Fortran-contiguous data or column
        sparse format (CSC) to avoid unnecessary memory duplication.

    y : array-like, shape (n_samples,)
        Observation vector.

    alpha : float
        Value of the Lasso regularization parameter.

    w_init : array-like, shape (n_features,), optional
        Initial value for the coefficients vector.

    max_iter : int, optional
        Maximum number of outer loop (working set definition) iterations.

    gap_freq : int, optional
        Number of epochs between every gap computation in the inner solver.

    max_epochs : int, optional
        Maximum number of epochs for the coordinate descent solver called on
        the subproblems.

    p0 : int, optional
        Size of the first working set.

    verbose : (0, 1), optional
        Verbosity level of the outer loop.

    verbose_inner : (0, 1), optional
        Verbosity level of the inner solver.

    tol : float, optional
        Optimization tolerance: the solver stops when the duality gap goes
        below ``tol`` or the maximum number of iteration is reached.

    prune : (0, 1), optional
        Whether or not to use pruning when growing the working sets.

    Returns
    -------
    w : array, shape (n_features,)
        Estimated coefficient vector.

    theta : array, shape (n_samples,)
        Dual point (potentially accelerated) when the solver exits.

    gaps : array
        Duality gap at each outer loop iteration.

    times : array
        Time elapsed since entering the solver, at each outer loop iteration.
    """

    alphas, coefs, _, thetas, all_gaps, all_times = celer_path(
        X, y, alphas=np.array([alpha]), coef_init=w_init, gap_freq=gap_freq,
        max_epochs=max_epochs, p0=p0, verbose=verbose,
        verbose_inner=verbose_inner, tol=tol, prune=prune, return_thetas=True,
        monitor=True)

    w = coefs.T[0]
    theta = thetas[0]
    gaps = all_gaps[0]
    times = all_times[0]

    return w, theta, gaps, times
